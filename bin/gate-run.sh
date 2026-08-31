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

# THE DISK. Checked before the first gate and after every one, because the expensive case is the
# MID-RUN crossing: a table with rows from both sides of the line and nothing saying which is which.
# See bin/disk-guard.sh for what a full disk cost on 2026-08-30.
# shellcheck source=bin/disk-guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/disk-guard.sh"
if ! disk_guard_check "before any gate ran"; then
  echo "gate-run: REFUSING TO START — there is not enough disk to trust the result." >&2
  echo "  This is not a verdict about $repo. Free space and run again." >&2
  exit 2
fi

run=0; ok=0; bad=0; skip=0; i=0; bad_pre_disk=0
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
  # A GATE WHOSE INTERPRETER IS NOT INSTALLED HERE DID NOT FAIL — IT DID NOT RUN. This is the exact
  # sibling of the `${{ }}` arm three cases up: that one exists because an unexpandable GitHub
  # expression made candor-java "permanently red for a reason that is not a defect in candor-java",
  # and a missing binary is the same thing by a different spelling. Only one of the two was handled.
  # Measured 2026-08-30 on this box: CI provides `python`, macOS ships only `python3`, so three
  # umbrella gates reported FAIL at rc=127 while all three assertions pass under python3.
  # Checked BEFORE running, on the leading word, rather than by treating rc=127 as a skip after the
  # fact: a gate that runs and whose SCRIPT then hits a missing tool has really failed, and reading
  # 127 off the whole command cannot tell those two apart. Skipping makes the verdict INCOMPLETE,
  # never OK — an unrunnable gate is still an unrun gate.
  if [ -z "$why" ]; then
    _lead="${cmd%% *}"
    case "$_lead" in
      # Only a bare command word. Anything with a slash is a path this repo owns (./gradlew,
      # bin/foo.sh) and its absence IS a defect; builtins and assignments are not lookups at all.
      */*|cd|echo|set|export|if|for|while|'['|test|*=*) ;;
      *) command -v "$_lead" >/dev/null 2>&1 || why="\`$_lead\` is not installed here (CI provides it)" ;;
    esac
  fi
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
  # A GATE THAT SKIPS ITSELF AND EXITS 0 IS COUNTED AS PASSED BY EVERYTHING, INCLUDING THIS FILE.
  # This tool's header says SKIPPED IS NOT PASSED — but that only ever governed skips THIS script
  # decided. A script that decides for itself and returns 0 was landing in the `ok` column.
  # Measured 2026-08-31 across two repos: candor-rust's oracle.sh, oracle_pf.sh, disclosure_recall.sh,
  # realworld/run.sh and realworld/run_deep.sh all print "needs Linux + strace (got Darwin) —
  # skipping" and exit 0; candor-java's run_kotlin.sh prints "kotlinc not installed — SKIPPED" and
  # exits 0. A local run reported 29/29 OK when 24 had executed.
  # Worse on the CI side: candor-rust's oracle.sh exits 0 when `strace` is merely ABSENT, so a failed
  # install would give a GREEN job over an unrun oracle. The only thing preventing that today is the
  # separate apt-get step failing first.
  # MATCHED ON THE LAST NON-EMPTY LINE ONLY, not anywhere in the output: these scripts announce the
  # skip as their final word, while an ordinary gate may legitimately say "skipping" about a sub-step
  # mid-run. Narrow on purpose — a false positive here understates coverage, which is loud, but a tool
  # that is permanently INCOMPLETE is a red nobody reads.
  # THE DURABLE FIX IS AT SOURCE: a self-skipping gate should exit non-zero (3) so no caller has to
  # pattern-match its prose. Until every repo does, this reads the prose and says so.
  _last=""
  [ -f "$log" ] && _last=$(grep -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -1)
  # TWO SPELLINGS, because matching only the SUFFIX missed EIGHT REAL EXIT POINTS in this family —
  # seven in this very repo and one in candor-rust — found by an adversarial review 2026-08-31:
  #   suffix-style   "soundness oracle: needs Linux + strace (got Darwin) — skipping"
  #   FRONT-LOADED   "SKIP: needs jq" · "SKIP: needs python3" · "SKIP: needs node"
  #                  "SKIP: test needs jq" · "SKIP: candor-query not built (run: cargo build …)"
  # All are `{ echo "SKIP: …"; exit 0; }`. Measured end-to-end against the real script: three such
  # gates reported `OK — every gate ran and passed`. The fix's own calibration set was the five rust
  # + one java soundness scripts named in its comment; it never included this repo's OWN test
  # scripts, so the class it claimed to close still had members. Section 16 pinned only the suffix
  # style, which is why the rows were green.
  # The front-loaded arm is anchored at the START and requires a delimiter, so an ordinary summary
  # ending "…, 3 skipped" cannot trip it — that false-positive direction would make the tool
  # permanently INCOMPLETE, which is a red nobody reads.
  # THREE ARMS, each requiring STRUCTURE rather than the mere presence of the word:
  #   1. suffix after a delimiter   "… (got Darwin) — skipping"  ·  "… not installed — SKIPPED"
  #   2. front-loaded before one    "SKIP: needs jq"  ·  "SKIP: candor-query not built"
  #   3. the bare word on its own line
  # A bare `\bSKIPPED$` arm was here and is DELETED: under `grep -i` it matched the ordinary summary
  # "40 passed, 0 failed, 3 skipped", downgrading a genuine full pass to SELFSKIP. My own fixture
  # caught it — the reviewer had flagged that direction as fragile-but-not-yet-real, and adding the
  # front-loaded arm without re-checking the old one is what made it real. It was also redundant:
  # arm 1 already catches "— SKIPPED" via its delimiter.
  # EXIT 3 IS THE CONVENTION; the prose match is the fallback for scripts that have not adopted it.
  # candor-rust's five strace gates now exit 3 on self-skip (2026-08-31), which is exactly what this
  # tool asked for — a caller should not have to pattern-match English. Without this arm they would
  # have flipped from SELFSKIP to FAIL on every non-Linux box the moment that landed: the reader must
  # learn the convention in the same change that the writers adopt it, or the fix reads as a break.
  if [ "$rc" -eq 3 ]; then
    skip=$((skip+1)); run=$((run-1))
    printf '  \033[33m%-6s\033[0m %s\n' "SELFSKIP" "$cmd"
    printf '         it exited 3 — the self-skip convention: it did not run%s\n' \
      "${_last:+, and said so: $_last}"
  elif [ "$rc" -eq 0 ] && printf '%s' "$_last" | grep -qiE '(—|-|:)[[:space:]]*skipp?(ing|ed)\.?$|^[[:space:]]*skipp?(ed|ing)?[[:space:]]*[:—-]|^[[:space:]]*skipp?(ed|ing)?[[:space:]]*$'; then
    skip=$((skip+1)); run=$((run-1))
    printf '  \033[33m%-6s\033[0m %s\n' "SELFSKIP" "$cmd"
    printf '         it exited 0 but its own last line says it did not run: %s\n' "$_last"
  elif [ "$rc" -eq 0 ]; then ok=$((ok+1)); printf '  \033[32m%-6s\033[0m %s\n' "OK" "$cmd"
  else bad=$((bad+1)); printf '  \033[31m%-6s\033[0m %s  (rc=%s, %s)\n' "FAIL" "$cmd" "$rc" "$log"; fi
  # AFTER the gate, not before: a gate that filled the disk itself is the one whose own rc is least
  # trustworthy, and checking first would clear it and then believe it.
  # Remember how many FAILs existed BEFORE the disk ever crossed. A failure recorded while the disk
  # was healthy cannot be ENOSPC noise, and telling the reader to disregard it would bury a real bug
  # behind an unrelated condition. Measured by an adversarial review 2026-08-31: a genuine rc=1 at
  # gate 1 with a healthy disk was reported as "NOT a finding" because the disk crossed at gate 3.
  _bad_before_crossing=$bad
  disk_guard_check "$cmd" || true
  [ "$CANDOR_DISK_BROKE" -eq 1 ] || bad_pre_disk=$_bad_before_crossing
done < "$GATELIST"
rm -f "${TMPDIR:-/tmp}/.candor-disk-guard-cursor-$$"

printf '\n%s: %s gate(s) run, %s ok, %s failed, %s skipped, %s block line(s) not auto-run\n' \
  "$repo" "$run" "$ok" "$bad" "$skip" "$manual"
[ "$manual" -gt 0 ] && printf '  (see `bash bin/gates.sh %s` for the ~ lines — those belong to multi-line steps and need reading)\n' "$repo"

# THE DISK VERDICT COMES FIRST, ahead of the accounting check and ahead of NOT GREEN. A full disk
# can CAUSE both — a gate that cannot write is a gate that did not run — so attributing it to
# accounting or to a defect in the repo would name the wrong cause. It also outranks `bad > 0`
# deliberately: a FAIL row produced after the crossing is not evidence of a defect, and reporting it
# as one is how ENOSPC noise gets filed as a finding.
if disk_guard_verdict_note >&2; then
  _suspect=$((bad - bad_pre_disk))
  echo "  Verdict withheld: this run measured $repo under a condition that fakes both failures and" >&2
  echo "  empty results." >&2
  if [ "$bad_pre_disk" -gt 0 ]; then
    # NOT "$bad FAIL rows are not findings". A FAIL recorded before the crossing happened on a
    # healthy disk and IS a finding; saying otherwise buries a real bug behind an unrelated
    # condition. Split them, and say which is which.
    echo "  $bad_pre_disk FAIL row(s) occurred BEFORE the crossing, on a healthy disk — those ARE" >&2
    echo "  real findings and must not be dismissed. $_suspect after it are unusable until re-run." >&2
  else
    echo "  $bad FAIL row(s) above are NOT findings until re-measured with room." >&2
  fi
  exit 2
fi
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
