#!/usr/bin/env bash
# shellcheck shell=bash
# _release_set.sh — THE CUT SET: which repos a release actually covers. Sourced by release-stage.sh,
# release-preflight.sh, release.sh, release-verify.sh, and scripts/update-candor.sh (for rs_tag_and_push
# alone — it does not derive a cut set); it is not runnable on its own.
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
# WHAT A SCOPED CUT CAN NOW DO, AND WHAT IT STILL CANNOT — the front door, updated 2026-08-25.
#
# This header used to end "ENGINE_PIN is ONE value for the whole family … so a scoped cut does NOT move
# it and does NOT cut an umbrella/Homebrew release". That was true and it cost a family republish: the
# 0.32.1 cut pushed five engines with no functional change to deliver one candor-java fix, because the
# front door had a single pin and no value of it said "java 0.32.1, everything else 0.32.0".
#
# `bin/candor` now carries a FAMILY pin (ENGINE_PIN) plus an optional PER-ENGINE pin each for java, ts,
# rust and swift, empty by default. So a one-engine cut can include the umbrella: it moves that engine's
# pin, leaves the family line alone, and brew hashes a tarball carrying the divergence. `candor update`
# then installs the patched engine and the family line for everything else.
#
# STILL TRUE, and the reason the umbrella is not automatically in every scoped cut: the umbrella is a
# REPO, so moving the front door means cutting an umbrella release (UMBRELLA_VERSION, a tag, a brew
# formula). A cut that names only `--only candor-java` publishes the engine and its per-engine consumer
# pins (adopt's CANDOR_JAVA_VERSION, jbang's script-ref, the IDE plugins' candorJavaVersion) and leaves
# the front door where it is — `candor update` keeps installing the family line. To move the front door
# too, put the umbrella in the cut: `--only candor-java,candor`.

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
# ENGINE_PIN itself keeps the `*family*` owner above: it is the FAMILY LINE, and only a family-wide cut
# moves it. The per-engine pins beside it are owned by their own repos and are checked separately (see
# rs_pin_violations below), because their assertion is not "does this line contain $VER" — it is a
# RESOLVED comparison that has to answer for the engines this cut is NOT publishing as well.

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

# ── THE FRONT DOOR'S PINS ────────────────────────────────────────────────────────────────────────────
# `bin/candor` declares ENGINE_PIN (the family line) and four optional per-engine pins. Read here, once,
# so preflight, release.sh and release-verify.sh ask the file the same question — four scripts deriving
# the repo set independently is the defect [8] exists to catch, and a pin is the same shape of hazard.
RS_PIN_ENGINES="java ts rust swift"
rs_pin_repo() { # engine → the repo that publishes it
  case "$1" in java) echo candor-java ;; ts) echo candor-ts ;; rust) echo candor-rust ;; swift) echo candor-swift ;; esac
}
rs_family_pin() { # $1 = path to bin/candor
  sed -n 's/^ENGINE_PIN="\([0-9][0-9.]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}
# The version `candor update` ACTUALLY fetches for one engine: its own pin when set, else the family
# line. Anchored on the DECLARATION (`^ENGINE_PIN_JAVA="0.32.1"`), never on the resolution line beneath
# it — that one holds a `${…:-…}` expression and would parse as an empty pin, i.e. as "follows the
# family", which is the answer that silently passes every check below.
rs_engine_pin() { # $1 = engine ; $2 = path to bin/candor
  local u o
  u="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  o="$(sed -n 's/^ENGINE_PIN_'"$u"'="\([0-9.]*\)"$/\1/p' "$2" 2>/dev/null | head -1)"
  [ -n "$o" ] && { printf '%s' "$o"; return 0; }
  printf '%s' "$(rs_family_pin "$2")"
}
# THE ONE RULE THE FRONT DOOR MUST SATISFY BEFORE THE UMBRELLA IS CUT. For every engine:
#   · its repo IS in this cut   → the dispatcher must resolve $VER for it. Otherwise the umbrella tarball
#     brew hashes installs the OLD engine for the very repo this release was cut to fix — the
#     0.18-engines-under-a-0.23-umbrella failure, now expressible one engine at a time.
#   · its repo is NOT in this cut → it must resolve something OTHER than $VER, because $VER was never
#     published for that engine and a pin naming a release that does not exist 404s on a user's machine.
# Family-wide this reduces to "all four resolve $VER" — the check that was always here, plus one it could
# not express: a LEFTOVER per-engine pin holding one engine behind while the family moves past it.
# Prints one line per violation; empty output means clean.
rs_pin_violations() { # $1 = path to bin/candor ; $2 = the version being cut
  local e repo p
  for e in $RS_PIN_ENGINES; do
    repo="$(rs_pin_repo "$e")"; p="$(rs_engine_pin "$e" "$1")"
    if rs_in_set "$repo"; then
      [ "$p" = "$2" ] || echo "$e is pinned to ${p:-unset}, not $2 — this cut publishes $repo@$2, and \`candor update\` would keep installing ${p:-nothing}"
    else
      [ "$p" != "$2" ] || echo "$e is pinned to $2, but $repo is NOT in this cut — that names a release nobody published"
    fi
  done
}
rs_is_full() { [ "${RS_FULL:-1}" = 1 ]; }
rs_count()   { printf '%s\n' $RS_SET | grep -c .; }

# ── VERSION COMPARISON, PLAIN X.Y.Z ONLY ────────────────────────────────────────────────────────────
# Every version this family cuts is a bare X.Y.Z (SPEC.md's own versioning policy — no pre-release or
# build-metadata suffixes), so a numeric field-by-field comparison is exact; nothing here needs a general
# semver grammar. Added for release-verify.sh, which needs to tell a per-engine pin that is BEHIND the
# release under verification (the 0.18-engines-under-a-0.23-umbrella failure, expressible per engine since
# 2026-08-25) apart from one that is merely AHEAD of it (the ordinary, expected shape of an unfinished
# one-engine patch — release-verify.sh's own header already says that must not read as broken, and until
# this existed nothing in the file could tell the two apart: both were a bare string inequality).
rs_ver_lt() { # $1 $2 — return 0 (true) if "$1" < "$2" ; 1 otherwise, including equal or unparseable
  [ "$1" = "$2" ] && return 1
  local IFS=. a b i ai bi
  # shellcheck disable=SC2206
  a=($1)
  # shellcheck disable=SC2206
  b=($2)
  for i in 0 1 2; do
    ai="${a[$i]:-0}"; bi="${b[$i]:-0}"
    # A non-numeric field means this isn't the X.Y.Z shape this function is for — refuse to guess which
    # side it falls on rather than risk a false "not less" (silently treated as AHEAD, i.e. disclosed
    # and not failed) OR a false "less" (a spurious hard failure). Callers see 1 either way and read it
    # as "not less"; a value this malformed already fails elsewhere (rs_engine_pin's own anchor regex).
    case "$ai$bi" in *[!0-9]*) return 1 ;; esac
    [ "$ai" -lt "$bi" ] && return 0
    [ "$ai" -gt "$bi" ] && return 1
  done
  return 1
}

# ── TAG THEN PUSH — REMOTE EXISTENCE, NOT LOCAL ─────────────────────────────────────────────────────
# `git tag && git push` used to be the whole guard, checked for idempotency on a rerun with
# `git rev-parse "$tag"`. Under `set -uo pipefail` (release.sh has no `-e`) that `&&` chain failing at
# the SECOND half — the push — does not die: the chain simply stops evaluating and the calling script
# carries on as if nothing happened. The tag exists locally but never reached origin. A rerun then asks
# `git rev-parse "$tag"`, which answers "do I have this ref" — always yes after the first attempt — so
# the push is never retried and the tag never reaches origin. For candor-ts (release.sh step 2) that
# means the OIDC `publish.yml` an origin push triggers never fires; the failure surfaces ~25 minutes
# later at the npm wait, pointing the operator at candor-ts's workflow, which was never triggered at
# all. The umbrella tag (step 7) and update-candor.sh's own umbrella tag share the identical shape.
#
# THE FIX ASKS THE REMOTE. `git ls-remote --exit-code --tags origin refs/tags/$tag` is the question
# every caller actually needs answered — has this tag reached the place its consumers read it from
# (npm's OIDC trigger, `gh release`, a fresh clone) — and `rev-parse` answers a different one. A tag
# that is local-but-not-remote is therefore "not yet done": the push is (re)attempted, and the existing
# local tag is reused rather than recreated (recreating it would move it off whatever commit the first,
# half-finished attempt tagged, on a repo where that commit might no longer be HEAD).
#
# NO RETRY LOOP HERE — unlike the Homebrew tap's rebase-and-retry (this repo's OWN
# scripts/update-candor.sh, further down, on the shared tap). The tap is the one repo in this whole
# path this maintainer does not solely control, so a rejected push there is routine, expected
# contention. Every tag this function pushes targets a repo this maintainer owns outright: a rejected
# push there means auth or network, not contention, and retrying would paper over a real failure
# instead of surfacing it. This is the over-charge control that keeps this fix distinct from the tap's.
#
# Returns 0 on a push that happened just now, 3 if the tag was already on origin (nothing to do — the
# caller prints its own "skip" wording), 1 on a genuine failure (a diagnostic is already on stderr).
rs_tag_and_push() { # $1 = tag (e.g. v0.32.1) ; $2 = annotate message, or "" for a lightweight tag ; run with $PWD inside the target repo
  local tag="$1" msg="${2:-}"
  if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    return 3
  fi
  if ! git rev-parse "$tag" >/dev/null 2>&1; then
    if [ -n "$msg" ]; then
      git tag -a "$tag" -m "$msg" || { echo "rs_tag_and_push: could not create local tag $tag" >&2; return 1; }
    else
      git tag "$tag" || { echo "rs_tag_and_push: could not create local tag $tag" >&2; return 1; }
    fi
  fi
  if git push origin "$tag"; then
    return 0
  fi
  echo "rs_tag_and_push: $tag exists locally but the push to origin FAILED — not retried automatically" \
       "(this repo is single-writer, so a rejected push means auth or network, not the tap's ordinary" \
       "contention). Fix access, then re-run: the local tag is kept and reused, only the push repeats." >&2
  return 1
}

# The one line every script prints when the cut is scoped, so a reader of any log can tell a partial cut
# from a family one WITHOUT being told which flag was used. A scoped run that looks like a full run is
# how "release-verify: OK" would come to mean less than it says.
rs_banner() { # $1 = the calling script's own note/info function name
  rs_is_full && return 0
  "$1" "CUT SET: $RS_SET  (scoped — the rest of the family is NOT moving; ENGINE_PIN and the umbrella stay on the family line)"
}
