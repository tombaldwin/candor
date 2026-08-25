#!/usr/bin/env bash
# shellcheck shell=bash
# _release_set.sh — THE CUT SET: which repos a release actually covers. Sourced by release-stage.sh,
# release-preflight.sh, release.sh and release-verify.sh; it is not runnable on its own.
#
# WHY THIS EXISTS. candor's own versioning policy (candor-spec SPEC.md, "Versioning policy", and
# [[candor-three-axis-versioning]]) says the family moves as a LADDER: the SPEC version is the shared
# contract, but the BUILD version is per-engine by construction — §2.1's staleness gate compares an
# engine-PREFIXED string, so nothing requires two engines to carry the same number, and preflight [4]
# says so in as many words ("a build id is PER-ENGINE by design … demanding equality DESTROYS the
# information the build id exists to carry").
#
# The TOOLING said the opposite. `release-verify.sh` demanded v$VER on all seven repos, crates.io
# max_version on four crates and npm at $VER; `release-preflight.sh` [3] demanded all seven cross-repo
# pins at $VER; `release.sh` published four crates, tagged npm and cut six GitHub releases
# unconditionally. So the only expressible release was a family-wide one, and the record shows the
# tooling — not a decision — is what made it so: candor-swift's and candor-agents' `## [0.29.1]`
# entries read, verbatim, "**Family build bump only — no engine changes in this repo.**", written by
# hand only because an empty `## Unreleased` would otherwise have made `release.sh` republish 0.29.0's
# notes under a 0.29.1 tag. Two repos republished to say they had not changed.
#
# THE DEFAULT IS UNCHANGED. With no `--only`, every script behaves exactly as before: the set is the
# whole family and every check, publish step and verification is the one it always was.
#
# WHAT A SCOPED CUT CANNOT DO, stated here because it constrains everything downstream:
# `bin/candor`'s ENGINE_PIN is ONE value for the whole family — `candor update` uses it for the java
# release tag, `cargo install --version "$ENGINE_PIN"`, `npx candor-ts@$ENGINE_PIN` and the swift
# binary's tag alike. It is therefore not expressible per engine, and moving it for a one-engine patch
# would point the other three at a version that does not exist. So a scoped cut publishes ENGINE
# releases and moves the PER-ENGINE pins (adopt's CANDOR_JAVA_VERSION and candor-agents@v, jbang's
# script-ref, the IDE plugins' candorJavaVersion/candorTsVersion) — it does NOT move ENGINE_PIN and does
# NOT cut an umbrella/Homebrew release. `candor update` keeps installing the family line until the
# family moves. That is a real limitation, not a rounding error, and every script says so where it bites.

# The family, in the order every loop in these scripts walks it. Deliberately ONE list: the repo sets
# in four scripts drifting apart is the defect preflight [8] exists to catch, and this is its root fix.
RS_FAMILY="candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor"

# WHICH REPO OWNS EACH CROSS-REPO PIN. A pin names ONE engine's version, so a cut moves exactly the pins
# whose owner it publishes — that is what makes preflight [3] answerable for a subset instead of
# demanding versions that will never exist. ENGINE_PIN's owner is the pseudo-repo `*family*`: it is the
# one pin no subset can move (see the header), so it is in scope only for a family-wide cut.
rs_pin_owner() { # $1 = pin label as used by preflight [3] / release-verify
  case "$1" in
    "adopt java  "|"adopt java"|jbang*|"jetbrains jvm") echo candor-java ;;
    "adopt agents") echo candor-agents ;;
    "vscode ts   "|"vscode ts"|"jetbrains ts") echo candor-ts ;;
    "engine pin  "|"engine pin") echo '*family*' ;;
    *) echo '*family*' ;;
  esac
}

# `--only` is accepted as a FLAG by every script and travels to child processes as CANDOR_ONLY, because
# `release.sh` invokes preflight and must pass the same set on without re-deriving it. Call this with
# "$@" and then `set -- "${RS_ARGS[@]+"${RS_ARGS[@]}"}"` — the flag is removed and the positional
# <spec> <ver> arguments each script already parses are untouched.
rs_split_args() {
  RS_ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --only=*) CANDOR_ONLY="${1#--only=}" ;;
      --only)
        # A MISSING VALUE IS AN ERROR, NOT AN EMPTY SET. `--only` with nothing after it would otherwise
        # set CANDOR_ONLY="" and silently mean "the whole family" — the widest possible action, chosen
        # by a typo, on the scripts that publish. Fail instead.
        shift
        [ "$#" -gt 0 ] || { echo "release: --only needs a value (e.g. --only candor-java)" >&2; exit 2; }
        CANDOR_ONLY="$1"
        ;;
      *) RS_ARGS+=("$1") ;;
    esac
    shift
  done
  export CANDOR_ONLY
}

# Resolve CANDOR_ONLY into RS_SET (a space-delimited subset of RS_FAMILY, in family order) and RS_FULL.
# An unrecognised name is FATAL: `--only jva` must not quietly cut nothing, and `--only` naming a repo
# outside the family must not quietly cut everything.
rs_init() {
  RS_SET="$RS_FAMILY"; RS_FULL=1
  local want="${CANDOR_ONLY:-}"
  [ -n "$want" ] || return 0
  local raw canon out=""
  for raw in ${want//,/ }; do
    case "$raw" in
      spec|candor-spec)     canon=candor-spec ;;
      rust|candor-rust)     canon=candor-rust ;;
      java|jvm|candor-java) canon=candor-java ;;
      ts|candor-ts)         canon=candor-ts ;;
      swift|candor-swift)   canon=candor-swift ;;
      agents|candor-agents) canon=candor-agents ;;
      umbrella|candor)      canon=candor ;;
      *) echo "release: --only: '$raw' is not a candor repo. Known: $RS_FAMILY (or the short forms spec rust java ts swift agents umbrella)" >&2; exit 2 ;;
    esac
    case " $out " in *" $canon "*) ;; *) out="$out $canon" ;; esac
  done
  # Re-emit in FAMILY ORDER, so `--only ts,java` and `--only java,ts` produce the same set and every
  # loop below walks the repos in the order the release always has. An ordering that depends on how the
  # operator typed the flag is a difference that shows up only in output diffs, which is exactly where a
  # regression hides.
  RS_SET=""
  local r
  for r in $RS_FAMILY; do
    case " $out " in *" $r "*) RS_SET="${RS_SET:+$RS_SET }$r" ;; esac
  done
  [ -n "$RS_SET" ] && { [ "$RS_SET" = "$RS_FAMILY" ] && RS_FULL=1 || RS_FULL=0; }
}

rs_in_set()  { case " $RS_SET " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
rs_is_full() { [ "${RS_FULL:-1}" = 1 ]; }
rs_count()   { printf '%s\n' $RS_SET | grep -c .; }

# The one line every script prints when the cut is scoped, so a reader of any log can tell a partial cut
# from a family one WITHOUT being told which flag was used. A scoped run that looks like a full run is
# how "release-verify: OK" would come to mean less than it says.
rs_banner() { # $1 = the calling script's own note/info function name
  rs_is_full && return 0
  "$1" "CUT SET: $RS_SET  (scoped — the rest of the family is NOT moving; ENGINE_PIN and the umbrella stay on the family line)"
}
