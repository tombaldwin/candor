#!/usr/bin/env bash
# THE AD-HOC PROBE HARNESS — for a measurement that is going to inform a decision.
#
# WHY THIS EXISTS, stated as it happened. In one session five ad-hoc measurements were WRONG, and every
# one produced a plausible reading that matched a story already in my head:
#
#   1. `for v in "callers f" ...; do $Q $v ...` — zsh does NOT word-split an unquoted expansion, so the
#      verb+arg went as ONE argv token, every engine answered "unknown command", and four uniform exit-2s
#      read as "all four verbs fail closed". The UNIFORMITY was the tell and it read as the finding.
#   2. A conformance suite was started, then an agent that edits an engine was resumed WHILE IT RAN. The
#      suite reads engines from their working trees, so a half-written file produced a DIVERGE that was
#      reported to that agent as a cardinal sin it had not committed.
#   3. `path f` — wrong arity. Exit 2 on both arms. Caught only because the CONTROL arm also failed.
#   4. `.build/release/candor-swift` probed while the suite builds and uses `.build/debug/`. The release
#      binary was 2h older than the commit under test; "the sidecars survived" was a stale binary.
#   5. `set -- $spec` — the SAME zsh splitting bug as (1), after the lesson had been written down, in a
#      matrix whose wrong answers happened to match the expected ones for 3 of 4 engines.
#
# THE ASYMMETRY THAT EXPLAINS ALL FIVE. Every conformance ROW written that day was falsified — the engine
# was deliberately broken, the row was confirmed to FAIL, the break was reverted. None of those was wrong.
# Every ad-hoc PROBE was unfalsified. Five were wrong. Rigour was applied to the artifact being built and
# not to the instrument building it, and the instrument is what decisions were made from.
#
# SO: a probe that will be cited in a spec clause, a commit message, or a delegation brief gets the same
# treatment as a row. This script is that treatment, mechanised.
#
#   probe.sh <control argv…> -- <subject argv…>
#
# WHAT IT ENFORCES
#   argv as an ARRAY          — the caller passes real argv after `--`; nothing is re-split, so (1)/(5)
#                               cannot happen. There is no string-splat path in this script.
#   a CONTROL that must differ — if the control and the subject agree, the harness is presumed broken and
#                               the run is REFUSED, not reported. (1)/(3)/(5) all die here.
#   binary PROVENANCE          — prints each binary's mtime against its repo HEAD commit time, and warns
#                               loudly when the binary predates the commit. (4) dies here.
#   a QUIET TREE               — refuses while any engine repo is dirty or a build/agent is running,
#                               because a measurement taken over a moving tree is not a measurement. (2).
#
# It deliberately does NOT try to interpret results. It makes the reading trustworthy; you still read it.
set -uo pipefail

ENGINES="candor-rust candor-java candor-ts candor-swift candor-spec"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

die() { echo "probe: $*" >&2; exit 2; }

# ── the quiet-tree gate ────────────────────────────────────────────────────────────────────────────
# A dirty tree is not automatically fatal (you may be probing your own edit) but it is NAMED, and a
# running build/suite is fatal: that is failure (2), and it produced a false cardinal-sin accusation.
quiet_tree_check() {
  local dirty=""
  for r in $ENGINES; do
    [ -d "$ROOT/$r" ] || continue
    if [ -n "$(git -C "$ROOT/$r" status --porcelain 2>/dev/null | grep -v '^?? ')" ]; then
      dirty="$dirty $r"
    fi
  done
  [ -n "$dirty" ] && echo "probe: NOTE — dirty tree(s):$dirty (your measurement includes uncommitted work)" >&2
  if pgrep -f "conformance/run.sh" >/dev/null 2>&1; then
    die "a conformance run is IN FLIGHT. It reads engines from their working trees; measuring now, or
      editing now, contaminates it in both directions. Wait for it."
  fi
  for p in "swift build" "gradlew" "cargo build" "cargo test"; do
    pgrep -f "$p" >/dev/null 2>&1 && die "a build is running ($p) — the binary you are about to probe may
      be replaced mid-run. Wait for it."
  done
}

# ── binary provenance ──────────────────────────────────────────────────────────────────────────────
# Failure (4): the suite builds candor-swift into .build/debug and ad-hoc probing reaches for
# .build/release. They drift the moment an agent commits without a release rebuild.
provenance() {
  local bin="$1" repo="" bt ct
  case "$bin" in
    */candor-rust/*)  repo="$ROOT/candor-rust"  ;;
    */candor-swift/*) repo="$ROOT/candor-swift" ;;
    */candor-ts/*)    repo="$ROOT/candor-ts"    ;;
    */candor-java/*)  repo="$ROOT/candor-java"  ;;
    *) return 0 ;;
  esac
  [ -e "$bin" ] || return 0
  bt=$(stat -f %m "$bin" 2>/dev/null || stat -c %Y "$bin" 2>/dev/null) || return 0
  ct=$(git -C "$repo" log -1 --format=%ct 2>/dev/null) || return 0
  printf '  provenance: %s\n              built %s · HEAD %s (%s)\n' \
    "$bin" "$(date -r "$bt" '+%H:%M:%S' 2>/dev/null)" \
    "$(date -r "$ct" '+%H:%M:%S' 2>/dev/null)" "$(git -C "$repo" log -1 --format=%h)"
  if [ "$bt" -lt "$ct" ]; then
    echo "  *** STALE: this binary PREDATES its repo HEAD. You are measuring older code than you think." >&2
    STALE=1
  fi
  case "$bin" in
    */.build/release/*) echo "  NOTE: conformance builds and uses .build/debug/ — this is the OTHER binary." >&2 ;;
  esac
}

# ARGUMENT FORM: `probe.sh <control argv…> -- <subject argv…>`. Nothing else.
#
# THE FIRST VERSION HAD A `--expect-differs` FLAG AND IT IMMEDIATELY MISFIRED: written after the `--`, it
# was swallowed into the SUBJECT argv, the engine rejected it as an unknown flag, and the run reported
# "control and subject differ" — true, for entirely the wrong reason. The tool built to stop a malformed
# argv producing a plausible reading produced one, on its first use, by the same mechanism.
#
# So there is no flag to misplace. A control is MANDATORY and the differ-check is unconditional. A probe
# whose control cannot be distinguished from its subject is not a probe.
CONTROL=(); SUBJECT=(); STALE=0; _seen=0
for tok in "$@"; do
  if [ "$tok" = "--" ] && [ "$_seen" = 0 ]; then _seen=1; continue; fi
  if [ "$_seen" = 0 ]; then CONTROL+=("$tok"); else SUBJECT+=("$tok"); fi
done
[ "$_seen" = 1 ] || die "usage: probe.sh <control argv…> -- <subject argv…>   (the -- is required)"
[ "${#SUBJECT[@]}" -gt 0 ] || die "no subject argv after --"
[ "${#CONTROL[@]}" -gt 0 ] || die "no control argv before --. A control is mandatory: it is the only thing
      that can tell a real finding from a broken harness. If you cannot name a case whose answer MUST
      differ, you do not yet know what you are measuring."

quiet_tree_check
echo "probe:"
provenance "${SUBJECT[0]}"

run_one() {  # prints "exit|stdout"
  local out rc
  out=$("$@" 2>/dev/null); rc=$?
  printf '%s|%s' "$rc" "$out"
}

S=$(run_one "${SUBJECT[@]}")
echo "  subject: ${SUBJECT[*]}"
echo "    exit=${S%%|*}  stdout=$(printf '%s' "${S#*|}" | tr -d '\n' | cut -c1-110)"

if [ "${#CONTROL[@]}" -gt 0 ]; then
  C=$(run_one "${CONTROL[@]}")
  echo "  control: ${CONTROL[*]}"
  echo "    exit=${C%%|*}  stdout=$(printf '%s' "${C#*|}" | tr -d '\n' | cut -c1-110)"
  if [ "$S" = "$C" ]; then
    echo
    die "CONTROL AND SUBJECT AGREE, and you said they must differ. The probe is presumed BROKEN, and this
      run is refused rather than reported. This is the check that catches a malformed argv (a verb and its
      argument passed as ONE token answer 'unknown command' for every input, which reads as a uniform
      finding), a wrong-arity invocation, and a binary that does not implement the thing under test."
  fi
  echo
  echo "  -> control and subject DIFFER; the probe discriminates."
fi
[ "$STALE" = 1 ] && exit 3
exit 0

# WHAT THIS DOES NOT DO, stated so it is not over-trusted. The differ-check catches a BROKEN probe — a
# malformed argv, a wrong arity, a binary that does not implement the subject. It cannot tell a MEANINGFUL
# difference from a trivial one: a control and a subject that differ only in an echoed name will pass it
# while measuring nothing. Choosing a control whose answer must differ IN KIND is still a judgement, and
# it is the judgement the whole exercise rests on. The harness makes a reading trustworthy enough to
# investigate; it does not make it a finding.
#
# AND THE STRONGER RULE THIS SCRIPT IS ONLY A FALLBACK FOR: if a measurement is going to be cited in a
# spec clause, it should become a CONFORMANCE ROW instead. A row is falsified by construction and re-runs
# forever; a probe is trusted once. bin/probe-causes.sh says the same thing about panels: "A panel finds a
# defect once; a matrix finds it every time anyone runs it."
