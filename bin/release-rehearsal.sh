#!/usr/bin/env bash
# release-rehearsal.sh — everything the release ladder does EXCEPT publishing, in ONE pass, reporting
# EVERY problem at once.
#
# WHY THIS EXISTS (2026-08-25, from the 0.32.0 retrospective). That cut went: rust CI red → fix → push →
# wait → swift red → fix → push → wait → spec red → fix → wait, and then preflight failures over three
# more rounds. Each loop is ~10 minutes of CI, and every one of those failures existed before the first
# push. `spec-bump.sh` already does the right thing for the engine suites — it runs every one and reports
# the failures together — and nothing did it for the ladder.
#
# The goal is ONE report with N problems, not N reports with one problem each. So no check here
# short-circuits another: a failing tree state does not stop the suites, a failing suite does not stop
# preflight, and the summary at the bottom is the complete list.
#
#   bash bin/release-rehearsal.sh 0.32 0.32.2
#   bash bin/release-rehearsal.sh 0.32 0.32.2 --only candor-java,candor
#   bash bin/release-rehearsal.sh 0.32 0.32.2 --docker      # the umbrella arm on linux/amd64
#
# BOTH ARGUMENTS ARE REQUIRED, and that is a deliberate refusal rather than a convenience. A bare
# `release-preflight.sh` runs in HEALTH MODE and prints `skipped: no version argument` for its CI,
# `## Unreleased` and conformance checks — its `OK` says nothing about a cut, and that OK has been quoted
# as a release gate. A rehearsal for an unnamed version is the same trap one level up, so there is no
# no-argument form of this script at all.
#
# ── WHAT A REHEARSAL CANNOT PROVE, stated up front because a green run must not be read as more ───────
#
#   · CI ON THE PUSHED COMMIT. Every arm here runs on your machine. `release-preflight [10]` asks GitHub
#     whether CI is green on each repo's HEAD, and until the commit is pushed the honest answer is that
#     the question has not been asked. The umbrella arm reproduces the umbrella's workflows; it does not
#     reproduce the runner, its image, its caches or its concurrency.
#   · REGISTRY STATE. Whether `candor-query 0.32.2` is already on crates.io, whether npm's OIDC publish
#     succeeds, whether a tag already has a Release. Those are facts about the published world, and
#     `release-verify.sh` is the thing that asks — AFTER a release exists.
#   · THE PUBLISH CALLS THEMSELVES. `cargo publish`, `gh release create`, the npm tag, the Homebrew tap.
#     `release-test.sh` drives `release.sh` against STUBS of all four (it runs in the umbrella arm), which
#     covers the sequencing and the arguments — not the network, the credentials or the remote's answer.
#   · ANYTHING DOWNSTREAM OF THE RELEASE EXISTING: `native.yml`'s release-event upload, the brew formula's
#     hash of a tarball that is not cut yet, `candor update` fetching an engine that is not published.
#
# Exit 0 only if every arm passed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CANDOR_ROOT:-$(cd "$HERE/../.." && pwd)}"

# shellcheck source=bin/_release_set.sh
. "$HERE/_release_set.sh"

DOCKER=""
ARGS=()
for a in "$@"; do
  case "$a" in
    --docker) DOCKER="--docker" ;;
    *) ARGS+=("$a") ;;
  esac
done
rs_split_args ${ARGS[@]+"${ARGS[@]}"}
set -- "${RS_ARGS[@]+"${RS_ARGS[@]}"}"
rs_init

SPEC="${1:-}"; VER="${2:-}"
if [ -z "$SPEC" ] || [ -z "$VER" ]; then
  cat >&2 <<'USAGE'
release-rehearsal: both the spec floor and the release version are required.

  bash bin/release-rehearsal.sh <spec> <version> [--only <repos>] [--docker]
  bash bin/release-rehearsal.sh 0.32 0.32.2

There is no no-argument form on purpose. `release-preflight.sh` with no version runs in HEALTH MODE and
skips its CI, `## Unreleased` and conformance checks while still printing OK — an OK that has been
quoted as a release gate. A rehearsal for an unnamed version would repeat that, so it refuses instead.
USAGE
  exit 2
fi
case "$VER" in
  "$SPEC".*) ;;
  *) echo "release-rehearsal: version '$VER' is not on spec floor '$SPEC' — check the argument order" >&2; exit 2 ;;
esac

TMP="$(mktemp -d)"
# The LOGS outlive this process on purpose: the summary names them as the place to look, and a summary
# citing a path its own EXIT trap has already deleted is worse than one that cites nothing.
LOGDIR="${TMPDIR:-/tmp}/candor-rehearsal-$VER"
rm -rf "$LOGDIR"; mkdir -p "$LOGDIR"
trap 'rm -rf "$TMP"' EXIT INT TERM
PROBLEMS="$TMP/problems"; : > "$PROBLEMS"

arm_start() { printf '\n── [%s] %s\n' "$1" "$2"; }
problem() { printf '%s\n' "$*" >> "$PROBLEMS"; }

echo "release-rehearsal — the whole ladder except publishing, all failures at once"
echo "  cut          : spec $SPEC / v$VER"
echo "  repos        : $RS_SET$( rs_is_full || echo "   (scoped — --only)" )"
echo "  root         : $ROOT"
echo "  arms run     : tree state, engine suites, umbrella workflows, release-preflight"
echo "  NOT proven   : CI on a pushed commit, registry state, the publish calls' network half"

# ── [1] TREE STATE, EVERY REPO AT ONCE ───────────────────────────────────────────────────────────────
# `release.sh` step 0 walks the same repos and `die`s on the FIRST one that is dirty or unpushed. Three
# dirty repos are therefore three runs of a script whose step 0 takes a minute. This asks all of them.
arm_start 1 "tree state — uncommitted work and unpushed commits (release.sh step 0, without the die)"
CLEAN_REPOS="$RS_SET"
case " $RS_SET " in *" candor "*) ;; *) CLEAN_REPOS="$RS_SET candor" ;; esac
tree_bad=0; tree_n=0
for r in $CLEAN_REPOS; do
  tree_n=$((tree_n + 1))
  d="$ROOT/$r"
  if [ ! -d "$d/.git" ]; then
    # NOT A SKIP. `git -C <missing> status --porcelain` fails to stderr and prints NOTHING to stdout —
    # identical to a real "no changes" answer to every check below — so a repo that was never cloned
    # (wrong CANDOR_ROOT, a fresh machine mid-bootstrap: [[candor-anya-second-machine]]) must not be
    # silently excluded from the count that backs "all N repo(s) clean and pushed" below. It is the one
    # thing this arm could not examine at all, which is the opposite of evidence that it is fine.
    printf "  ✘ %-16s not a git repo at %s — cannot verify clean/pushed state\n" "$r" "$d"
    problem "[1] $r: not a git repo at $d — release.sh step 0 dies on this rather than reading it as clean"
    tree_bad=$((tree_bad + 1))
    continue
  fi
  dirty="$(git -C "$d" status --porcelain | grep -c .)"
  ahead="$(git -C "$d" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")"
  msg=""
  [ "$dirty" != 0 ] && msg="$dirty uncommitted file(s)"
  case "$ahead" in
    0) ;;
    "?") msg="${msg:+$msg; }no upstream branch — nothing to compare a push against" ;;
    *)   msg="${msg:+$msg; }$ahead unpushed commit(s)" ;;
  esac
  if [ -n "$msg" ]; then
    printf "  ✘ %-16s %s\n" "$r" "$msg"
    problem "[1] $r: $msg — release.sh step 0 refuses on this"
    tree_bad=$((tree_bad + 1))
  else
    printf "  ✔ %-16s clean and pushed\n" "$r"
  fi
done
[ "$tree_bad" = 0 ] && echo "  all $tree_n repo(s) clean and pushed"

# ── the three slow arms, CONCURRENTLY ────────────────────────────────────────────────────────────────
# They are independent and each is minutes long. Run in sequence the wall time is their sum; run
# together it is the slowest. Output is buffered per arm and printed on completion so they cannot
# interleave — the same shape `verify-local.sh` settled on for the same reason.
E_LOG="$LOGDIR/engines.log"; U_LOG="$LOGDIR/umbrella.log"; P_LOG="$LOGDIR/preflight.log"

engines_arm() {
  if rs_is_full; then
    bash "$HERE/verify-local.sh"
  else
    # A scoped cut runs the suites of the repos it publishes. candor-spec and the umbrella have no
    # verify-local arm of their own — the umbrella's is arm [3] below, and candor-spec's suite is
    # conformance, which release-preflight [11] owns.
    local r rc=0 any=0
    for r in $RS_SET; do
      case "$r" in
        candor-rust|candor-ts|candor-java|candor-swift|candor-agents)
          any=1; bash "$HERE/verify-local.sh" "$r" || rc=1 ;;
      esac
    done
    [ "$any" = 0 ] && echo "  (no engine repo in this cut — nothing for verify-local to run)"
    return "$rc"
  fi
}
( engines_arm  >"$E_LOG" 2>&1; echo $? > "$TMP/e.rc" ) &
( bash "$HERE/verify-umbrella.sh" --all $DOCKER >"$U_LOG" 2>&1; echo $? > "$TMP/u.rc" ) &
# PINS_ADVISORY=1 is what `release.sh` step 0 sets, and for the same reason: check [3] asserts the
# cross-repo pins name $VER, and they cannot until $VER has been published. Strict here is a deadlock,
# not a safeguard. Setting it differently from the real gate would make this rehearsal red where the
# ladder is green, which is the way a gate gets ignored.
( PINS_ADVISORY=1 bash "$HERE/release-preflight.sh" "$SPEC" "$VER" \
    ${CANDOR_ONLY:+--only "$CANDOR_ONLY"} >"$P_LOG" 2>&1; echo $? > "$TMP/p.rc" ) &
wait

rc_of() { cat "$TMP/$1.rc" 2>/dev/null || echo 99; }

# EVERY FINDING BECOMES ITS OWN LINE, not one line per arm. "1 problem" for an arm holding five of them
# is the under-count `release-preflight`'s own `bad()` was fixed for — a report that under-counts its
# findings is the same shape as an engine that under-reports, and worse here, because the number is what
# tells you whether the last fix helped.
harvest() {  # $1 arm number ; $2 rc-key ; $3 log ; $4 grep -E pattern for one finding per line
  [ "$(rc_of "$2")" != 0 ] || return 0
  local found=0 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    found=$((found + 1))
    problem "[$1] $(printf '%s' "$line" | sed 's/^ *//; s/  */ /g' | cut -c1-140)"
  done <<EOF
$(grep -E "$4" "$3" | head -25)
EOF
  # A non-zero arm whose pattern matched nothing must still produce a line. Otherwise a failure the
  # harvester cannot parse disappears, and the run reports "no problems" while exiting non-zero.
  [ "$found" = 0 ] && problem "[$1] arm exited non-zero with no line this report could parse — read $3"
  return 0
}

arm_start 2 "engine suites — what each engine's own CI runs (bin/verify-local.sh)"
tail -30 "$E_LOG"
harvest 2 e "$E_LOG" "✘ FAILED"

arm_start 3 "umbrella workflows — derived from .github/workflows/*.yml (bin/verify-umbrella.sh --all)"
sed -n '/^  [a-z]/,$p' "$U_LOG" | head -40
harvest 3 u "$U_LOG" "✘ FAILED"

arm_start 4 "release-preflight $SPEC $VER — the real gate, which already reports all its findings"
grep -E "^\[|✘" "$P_LOG" | head -60
harvest 4 p "$P_LOG" "^ *✘ "

# ── the one report ───────────────────────────────────────────────────────────────────────────────────
echo
echo "══ REHEARSAL SUMMARY ═════════════════════════════════════════════════════════════════════════"
n="$(grep -c '^\[' "$PROBLEMS")"
if [ "$n" = 0 ]; then
  echo "  no problems found in 4 arm(s)."
else
  arms="$(sed -n 's/^\(\[[0-9]*\]\).*/\1/p' "$PROBLEMS" | sort -u | tr -d '\n')"
  echo "  $n problem(s) across arm(s) $arms — ALL of them, in one pass:"
  echo
  sed 's/^/  /' "$PROBLEMS"
fi
cat <<EOF

  FULL LOGS, kept after this run: $LOGDIR/
      engines.log   umbrella.log   preflight.log

  WHAT IS STILL UNPROVEN AFTER A GREEN RUN — not hedging, these are outside a local rehearsal:
    · CI on the pushed commit. release-preflight [10] asks GitHub about each repo's HEAD; a commit that
      is not pushed has not been asked about. Push, then re-run preflight alone.
    · Registry state: crates.io / npm / an existing tag or Release for v$VER.
    · The publish calls' network half. release-test.sh drives release.sh against STUBS — sequencing and
      arguments are covered, the remote's answer is not.
    · Anything downstream of the release existing: native.yml's release-event upload, the brew formula's
      hash of an uncut tarball, \`candor update\` fetching an unpublished engine.
EOF

[ "$n" = 0 ] || exit 1
echo "release-rehearsal: OK — $SPEC / $VER is as ready as a local run can show"
exit 0
