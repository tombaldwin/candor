#!/usr/bin/env bash
# changelog-lag.sh — HAS THE CHANGELOG KEPT UP WITH THE SOURCE SINCE THE LAST RELEASE?
#
#   bash bin/changelog-lag.sh            # every repo
#   bash bin/changelog-lag.sh candor-ts  # one repo
#
# WHY, stated as it happened. `release-stage.sh` renames `## Unreleased` to `## [X.Y.Z] — <date>` at
# STAGING time. Work then continues and lands inside that section, which is right — but the section's
# NARRATIVE was written for the tree as it stood when it was cut. The 0.27 sections described "resolves
# + fs kinds" while the release had grown thirty more privacy keys, `--target`, `--xml`, a new §2 field
# and three rounds of review fixes. Nothing failed. The file describing the release simply stopped
# keeping up, and no gate had an opinion about it.
#
# Preflight [5] already asks "does the file describing this release MENTION this release?" — a necessary
# condition a stale section passes trivially. This asks the one that was missing: did the description
# stop moving while the thing it describes kept going?
#
# ── TWO DESIGN MISTAKES, BOTH MADE HERE, BOTH KEPT ────────────────────────────────────────────────────
#
# 1. THE INVARIANT IS RECENCY, NOT PER-COMMIT AUTHORSHIP. Requiring every source commit to touch
#    CHANGELOG.md reported 33 "misses" across seven repos, of which most were false: the entry HAD been
#    written, one commit later. A rule that flags work already documented is a rule nobody reads. So the
#    question is whether the newest SOURCE commit is newer than the newest CHANGELOG commit, and the
#    commits in between are named so triage is a read rather than an investigation.
#
# 2. THE SOURCE SET MUST BE A DENYLIST. The second version listed the directories that hold source —
#    Sources, src, crates, lib, bin, … — and went green on seven repos while SILENTLY SKIPPING TWO of
#    them: candor-ts ships `scan.mjs`, `policy.mjs`, `lsp.mjs` at the repository ROOT, and candor-agents
#    ships a `candor_agents/` python package. Neither name was on the list, so neither repo had any
#    source at all as far as the check could see, and both printed nothing rather than a pass or a fail.
#    That is this project's own cardinal sin wearing a shell script: absence read as a clean bill.
#    An allowlist's omissions are silent; a denylist's are loud, so the list below names what does NOT
#    ship and everything else counts. An over-inclusion costs one `touch` of the changelog. A missed
#    repo costs a release that says less than it does.
set -uo pipefail
ROOT="${CANDOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
REPOS="${1:-candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor}"

# What does NOT ship, as git exclude-pathspecs. Tests, fixtures, evidence, CI, build output, vendored
# trees, and prose. Prose is here because a README edit is not a behaviour change; the ONE prose file
# that is a product — candor-spec's SPEC.md — is added back per-repo below, since git pathspecs cannot
# re-include after an exclude.
NOSHIP=(':(exclude)*.md' ':(exclude)LICENSE*' ':(exclude).github' ':(exclude).gitignore'
        ':(exclude)tests' ':(exclude)Tests' ':(exclude)test' ':(exclude)*_test.*' ':(exclude)test_*'
        ':(exclude)fixture*' ':(exclude)Fixtures' ':(exclude)eval' ':(exclude)soundness'
        ':(exclude)docs' ':(exclude)node_modules' ':(exclude)build' ':(exclude)target'
        ':(exclude).build' ':(exclude)*.egg-info' ':(exclude)*.lock' ':(exclude)*lock.json'
        ':(exclude)out.*' ':(exclude)conformance')
# Paths that ship DESPITE matching an exclude above. candor-spec's product is a document, and the
# conformance suite is the executable half of the same contract — a new PART is a shipped change there
# in the way a new unit test is not in an engine.
# Read via INDIRECT expansion below (`ev="EXTRA_${r//-/_}[@]"`), which the linter cannot follow.
# Renaming this silently disables the per-repo extra paths.
# shellcheck disable=SC2034
EXTRA_candor_spec=(SPEC.md conformance)

newest() { # repo-dir, since-rev, pathspec… -> committer timestamp of the newest matching commit, or ""
  local d="$1" rev="$2"; shift 2
  git -C "$d" log -1 --format=%ct "$rev..HEAD" -- "$@" 2>/dev/null
}

lag=0
for r in $REPOS; do
  d="$ROOT/$r"
  [ -d "$d/.git" ] || { printf '  \033[31m✘\033[0m %-14s not a git checkout at %s — NOT CHECKED\n' "$r" "$d"
                        lag=$((lag+1)); continue; }
  tag="$(git -C "$d" tag --sort=-v:refname 2>/dev/null | grep -E '^v[0-9]' | head -1)"
  [ -n "$tag" ] || { printf '  \033[33m·\033[0m %-14s no release tag — nothing to measure since\n' "$r"; continue; }

  # TWO QUERIES, NEVER ONE. A git pathspec cannot re-include after an exclude, so `SPEC.md` beside
  # `:(exclude)*.md` is excluded — the EXTRA set has to be asked for separately and merged. The
  # timestamp comparison below always did this; the commit LIST did not, and the two bugs that produced
  # were both invisible on a green tree and both found by the negative control:
  #   · it appended `"${extra[@]:-}"`, which for a repo with NO extra expands to one EMPTY STRING —
  #     a pathspec matching nothing, so a failing repo printed its ✘ and then no commits at all;
  #   · and for candor-spec, whose extra IS the point, the combined spec silently dropped SPEC.md.
  # Either way the promise that triage is a read rather than an investigation broke on exactly the path
  # that needs it.
  ev="EXTRA_${r//-/_}[@]"; extra=("${!ev:-}")
  csrc="$(newest "$d" "$tag" "${NOSHIP[@]}")"
  if [ -n "${extra[0]:-}" ]; then
    e="$(newest "$d" "$tag" "${extra[@]}")"
    [ -n "$e" ] && { [ -z "$csrc" ] || [ "$e" -gt "$csrc" ]; } && csrc="$e"
  fi
  [ -n "$csrc" ] || { printf '  \033[32m✔\033[0m %-14s no shipped change since %s\n' "$r" "$tag"; continue; }

  # TOPOLOGY, NOT TIMESTAMPS — the third design mistake in this script, and the one an adversarial
  # review found rather than I did. Comparing committer DATES greened over an ordinary merge: cut a
  # branch, touch the changelog on main, then merge the branch. The branch's source commits land on
  # main AFTER the changelog moved, are described nowhere, and carry OLDER `%ct` values — so the
  # newest source date was less than the newest changelog date and the check printed ✔. A wrong
  # CLEAR, which is the class this script's own header calls the cardinal sin.
  #
  # `<changelog-commit>..HEAD` asks the question dates cannot: is there a source commit that is NOT an
  # ancestor of the changelog's last touch? A merged side branch is exactly that, whatever its dates.
  ccl="$(git -C "$d" log -1 --format=%H "$tag..HEAD" -- CHANGELOG.md 2>/dev/null)"
  if [ -n "$ccl" ]; then
    unrec="$(git -C "$d" rev-list --count "$ccl..HEAD" -- "${NOSHIP[@]}" 2>/dev/null || echo 0)"
    if [ -n "${extra[0]:-}" ]; then
      unrec=$((unrec + $(git -C "$d" rev-list --count "$ccl..HEAD" -- "${extra[@]}" 2>/dev/null || echo 0)))
    fi
    if [ "${unrec:-0}" -eq 0 ]; then
      printf '  \033[32m✔\033[0m %-14s CHANGELOG.md covers every source commit since %s\n' "$r" "$tag"
      continue
    fi
  fi

  # BOTH failing branches name the commits. The "never touched" one did not, and the fixture in
  # release-test.sh §7 landed on exactly that branch — a repo whose only changelog commit is the tagged
  # one is the ORDINARY shape right after a release, not an edge case. The reader's need is identical
  # either way: which commits am I writing about?
  if [ -z "$ccl" ]; then
    printf '  \033[31m✘\033[0m %-14s source changed since %s and CHANGELOG.md never did:\n' "$r" "$tag"
    since=("$tag..HEAD")
  else
    printf '  \033[31m✘\033[0m %-14s source commits the CHANGELOG has not caught up with:\n' "$r"
    since=("$ccl..HEAD")
  fi
  list="$( { git -C "$d" log --format='%ct %h %s' "${since[@]}" -- "${NOSHIP[@]}" 2>/dev/null
             [ -n "${extra[0]:-}" ] && git -C "$d" log --format='%ct %h %s' "${since[@]}" \
               -- "${extra[@]}" 2>/dev/null; } \
           | sort -rn -k1,1 | awk '!seen[$2]++' | cut -d" " -f2- | head -8 | cut -c1-106 | sed 's/^/      /')"
  # An empty list under a ✘ means the PATHSPEC is wrong, not that there is nothing to fix. Say which,
  # rather than leaving a reader to conclude the check is broken and stop reading it.
  if [ -n "$list" ]; then printf '%s\n' "$list"
  else echo "      (no commits matched the source pathspec — the CHECK is wrong here, not the tree)"; fi
  lag=$((lag+1))
done

# ── EXACTLY ONE `## Unreleased` PER FILE ───────────────────────────────────────────────────────────
# `release-stage.sh` renames the FIRST `## Unreleased` to the version being cut. A file holding more
# than one therefore ships work that stays labelled unreleased, in a section a reader has no reason to
# distrust — the same class as the empty-stub trap, where an EMPTY first section makes `release.sh`
# publish the PREVIOUS version's notes.
#
# FOUND BY WALKING INTO IT: candor-rust had THREE (two with content, one an empty stub left above
# [0.30.0]) and candor-java had two, and the only reason it surfaced was an unrelated edit asserting its
# anchor appeared once. Nothing was checking, and both files would have been cut that way.
#
# An EMPTY section counts too — it is the residue that produces the duplicates, and it is exactly what
# `release.sh` mis-handles.
dupe=0
for r in $REPOS; do
  d="$ROOT/$r"; f="$d/CHANGELOG.md"
  [ -f "$f" ] || continue
  # ONLY THE REGION ABOVE THE FIRST RELEASED VERSION. That is the region the stager rewrites, so it is
  # the only region where a second header does damage. Counting the whole file called candor-rust bad
  # for `## [Unreleased] (nightly lint)` at line 2216 — a title inside long-released history, which
  # ships nothing and moves nowhere. A check that flags settled history gets read as noise and then
  # stops being read at all.
  n="$(awk '/^## \[[0-9]/ {exit} /^## \[?Unreleased/ {c++} END {print c+0}' "$f")"
  if [ "$n" -gt 1 ]; then
    printf '  \033[31m✘\033[0m %-14s %s `## Unreleased` sections — the stager renames only the FIRST,\n' "$r" "$n"
    echo   "                 so the rest ship still labelled unreleased. Merge them into one:"
    awk '/^## \[[0-9]/ {exit} /^## \[?Unreleased/ {printf "                   line %d: %s\n", NR, $0}' "$f"
    dupe=$((dupe+1))
  fi
done

echo
if [ "$dupe" -gt 0 ]; then
  printf '\033[31mchangelog-lag: %d changelog(s) hold more than one Unreleased section.\033[0m\n' "$dupe"
  exit 1
fi
if [ "$lag" -gt 0 ]; then
  printf '\033[31mchangelog-lag: %d repo(s) describe less than they ship.\033[0m\n' "$lag"
  echo "A pure refactor legitimately needs no entry — touch the file, or write the line."
  exit 1
fi
printf '\033[32mchangelog-lag: OK — every changelog is at least as new as its source\033[0m\n'
