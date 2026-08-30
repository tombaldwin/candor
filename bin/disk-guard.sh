#!/usr/bin/env bash
# A FULL DISK MAKES EVERY MEASUREMENT UNTRUSTWORTHY, AND IT DOES IT SILENTLY.
#
# Measured 2026-08-30. Six agents ran concurrently; one session directory reached 26G and the volume
# hit zero. What that cost was not the lost work — it was that the failures became indistinguishable
# from findings:
#
#   - Test suites failed for want of space. A suite that fails because it cannot write a temp file
#     looks exactly like a suite that fails because the code is wrong. Four agents were mid-run.
#   - The harness could not write a command's own output file, so commands DIED BEFORE EXECUTING and
#     returned nothing. This family has already recorded the shape once: "ad-hoc agent harnesses
#     return a clean zero having executed nothing."
#   - The verification tooling in this directory was itself the thing that could not run.
#
# THE DANGEROUS CASE IS THE MID-RUN CROSSING, NOT THE START. A run that begins with room and fills
# halfway through reports rows from both sides of the line in one table, and nothing in the output
# says which. A check that only runs at startup is blind to exactly that, so this one is designed to
# be called REPEATEDLY and to latch.
#
# WHY IT LATCHES AND NEVER CLEARS. If space comes back, the gates that already ran under pressure do
# not become trustworthy again — they ran under a condition that can produce a false FAIL and, worse,
# a false empty result. Once crossed, the verdict for that whole run is INCOMPLETE. That is the same
# fail-closed shape the spec requires of an engine that could not read part of its input: not a
# smaller green number, an admission.
#
# Usage:
#   bash bin/disk-guard.sh                 # print free space; exit 2 if below the floor
#   bash bin/disk-guard.sh --quiet         # exit status only
#   source bin/disk-guard.sh               # defines disk_free_mb / disk_guard_check / disk_guard_broke
#
# The floor is CANDOR_DISK_FLOOR_MB (default 2048). It is a floor for STARTING work, not a
# prediction of what a run needs: a rust build or a Docker leg can consume many GB, so passing here
# is not a promise that a run will fit — it is a refusal to start one that certainly will not.

CANDOR_DISK_FLOOR_MB="${CANDOR_DISK_FLOOR_MB:-2048}"

# Free megabytes on the filesystem holding $1 (default: the current directory).
# `df -Pk` is the POSIX form and prints ONE line per filesystem with a fixed column order on both
# BSD and GNU. Plain `df -h` differs between them, and `df` alone wraps long device names onto a
# second line, which shifts $4 to the wrong field — that wrap is why this uses -P and not -k alone.
disk_free_mb() {
  local target="${1:-.}" out
  # Not `df ... | awk`: a pipeline hides df's own failure, and this file exists because instruments
  # that cannot fail get believed. Capture first, check, then parse.
  out=$(df -Pk "$target" 2>/dev/null) || { echo "" ; return 1; }
  printf '%s\n' "$out" | awk 'NR==2 { print int($4 / 1024) }'
}

# The two filesystems a run can exhaust are not always the same one: the repo may be on the data
# volume while TMPDIR is elsewhere (a RAM disk, a separate mount, a container overlay). Reporting
# only the repo's would have been green during the 2026-08-30 outage if TMPDIR had been the full one.
# So: check both, and answer with the WORSE.
disk_guard_min_mb() {
  local a b tmp="${TMPDIR:-/tmp}"
  # INJECTION POINT, the same one CANDOR_ROOT is for gates.sh. A guard whose main path cannot be
  # driven is a guard nobody has watched fail, and this file's whole subject is instruments that
  # look like they ran. CANDOR_DISK_FAKE_FREE_MB is a comma-separated SEQUENCE consumed one value
  # per call — a single number cannot express the case that matters, which is healthy-then-breached
  # partway through a loop. The last value repeats once the list is exhausted.
  if [ -n "${CANDOR_DISK_FAKE_FREE_MB:-}" ]; then
    # THE CURSOR LIVES IN A FILE, NOT A VARIABLE, and that is not a style choice. This function is
    # called as `free=$(disk_guard_min_mb ...)` — a SUBSHELL — so a variable advanced here is
    # discarded when it returns. The first version of this block did exactly that: the sequence
    # never advanced, every call returned the FIRST value, and the mid-run crossing this injection
    # point exists to drive could not fire. It was caught only because the test for that crossing
    # was written and watched, which is the whole argument for writing it.
    # `$$` is the PARENT shell's pid inside a subshell (BASHPID is the subshell's), so one run gets
    # one cursor.
    local cur idx val n=1
    cur="${TMPDIR:-/tmp}/.candor-disk-guard-cursor-$$"
    idx=$(cat "$cur" 2>/dev/null) || idx=0
    [ -z "$idx" ] && idx=0
    # Walk to the idx'th field; the LAST value repeats once the list is exhausted, so a short
    # sequence means "and stay there" rather than falling off into a real df reading.
    val="${CANDOR_DISK_FAKE_FREE_MB%%,*}"
    local rest="$CANDOR_DISK_FAKE_FREE_MB"
    while [ "$n" -le "$idx" ]; do
      case "$rest" in
        *,*) rest="${rest#*,}"; val="${rest%%,*}" ;;
        *)   break ;;
      esac
      n=$((n+1))
    done
    echo $((idx + 1)) > "$cur" 2>/dev/null || true
    echo "$val"
    return
  fi
  a=$(disk_free_mb "${1:-.}")
  b=$(disk_free_mb "$tmp")
  [ -z "$a" ] && a=-1
  [ -z "$b" ] && b=-1
  # A df that FAILED reports -1 and is treated as below any floor. Fail closed: an unreadable
  # filesystem is not a healthy one, and "I could not tell" must never read as "there is room".
  if [ "$a" -lt 0 ] || [ "$b" -lt 0 ]; then echo -1; return; fi
  if [ "$a" -lt "$b" ]; then echo "$a"; else echo "$b"; fi
}

# THE LATCH. Set once, never cleared. Callers read it after their loop.
CANDOR_DISK_BROKE=0
CANDOR_DISK_BROKE_AT=""

# disk_guard_check [label] — returns 0 if healthy, 1 if the floor is breached. Latches on breach and
# records the label of the FIRST crossing, because that is the point after which nothing in the run
# is evidence. Callers should keep going and downgrade the verdict rather than abort mid-loop: a run
# killed halfway leaves a tree in an unknown state, which is its own untrustworthy measurement.
disk_guard_check() {
  local label="${1:-}" free
  free=$(disk_guard_min_mb "$PWD")
  if [ "$free" -lt "$CANDOR_DISK_FLOOR_MB" ]; then
    if [ "$CANDOR_DISK_BROKE" -eq 0 ]; then
      CANDOR_DISK_BROKE=1
      CANDOR_DISK_BROKE_AT="$label"
      printf '\033[31mdisk-guard: %s MB free — below the %s MB floor%s\033[0m\n' \
        "$free" "$CANDOR_DISK_FLOOR_MB" "${label:+, first seen at: $label}" >&2
      printf '  Every result from here on is suspect: a failure for want of space is\n' >&2
      printf '  indistinguishable from a real one, and a command that cannot write its own\n' >&2
      printf '  output returns nothing while looking like it ran.\n' >&2
    fi
    return 1
  fi
  return 0
}

# disk_guard_verdict_note — prints the line a caller should append to an INCOMPLETE verdict.
disk_guard_verdict_note() {
  [ "$CANDOR_DISK_BROKE" -eq 0 ] && return 1
  printf 'disk-guard: THE DISK CROSSED THE FLOOR DURING THIS RUN%s.\n' \
    "${CANDOR_DISK_BROKE_AT:+ (first seen at: $CANDOR_DISK_BROKE_AT)}"
  printf '  Rows above this point and rows below it were produced under different conditions and\n'
  printf '  the table does not say which is which. Free space and re-run before believing any of it.\n'
  return 0
}

# Standalone mode. `return` succeeds only when sourced, so this runs the CLI exactly when executed.
# BASH_SOURCE would work too, but this form is what the rest of bin/ already uses.
(return 0 2>/dev/null) || {
  set -uo pipefail
  _free=$(disk_guard_min_mb "$PWD")
  if [ "${1:-}" != "--quiet" ]; then
    if [ "$_free" -lt 0 ]; then
      echo "disk-guard: could not read free space (df failed) — treating as BELOW the floor." >&2
    else
      printf 'disk-guard: %s MB free (floor %s MB) — repo %s, TMPDIR %s\n' \
        "$_free" "$CANDOR_DISK_FLOOR_MB" "$PWD" "${TMPDIR:-/tmp}"
    fi
  fi
  [ "$_free" -lt "$CANDOR_DISK_FLOOR_MB" ] && exit 2
  exit 0
}
