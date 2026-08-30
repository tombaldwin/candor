#!/usr/bin/env bash
# release-stage.sh — perform the MECHANICAL half of staging a release, so a human does not.
#
#   bash bin/release-stage.sh 0.26.0
#   bash bin/release-stage.sh 0.32.1 --only candor-java     # a SCOPED patch: stage that repo alone
#
# `--only <repos>` stages a SUBSET. Every site belongs to exactly one repo, so a scoped run edits the
# sites of the repos being cut and leaves the rest on the version they last published — which is what
# the three-axis model says a build id is for. Without the flag nothing changes: the set is the family
# and all ~19 sites move, exactly as before.
#
# WHY THIS EXISTS. `release-preflight.sh` DETECTS that the build versions, the inter-crate deps, the
# gradle version and the `## Unreleased` sections are stale; nothing PERFORMED the bump, so a person
# hand-edited ten sites across six repos on release day. That is where the 0.25 release actually failed —
# the workspace root still requiring `^0.24.0`, candor-java's gradle version, a hyphenated `spec-0.24`,
# two test LABELS bumped without their VALUES — every one an edit someone made by hand at the end of a
# long day. 0.24 lost three steps the same way.
#
# WHAT IT DOES NOT DO, deliberately:
#   · it does not touch the SPEC declarations (`SPEC_VERSION`, `specVersion`, …). The spec floor is a
#     LADDER decision made when the rung lands, not a release-day mechanic — different axis, different
#     moment, and conflating them is how a build bump quietly moves a contract.
#   · it does not commit, tag, or push. It edits the working trees and stops, so the diff is reviewed by
#     a person before anything becomes permanent.
#   · it does not update the cross-repo PINS (adopt/, jbang, ENGINE_PIN). Those name a PUBLISHED release
#     and are updated AFTER it exists — preflight [3] says so in as many words.
#
# Idempotent: re-running with the same version is a no-op that reports "already at".
# Verify with `bash bin/release-preflight.sh <spec> <version>` afterwards — this script stages, that one
# judges, and they are deliberately separate programs.
set -uo pipefail
HERE_S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/_release_set.sh
. "$HERE_S/_release_set.sh"
rs_split_args "$@"
set -- "${RS_ARGS[@]+"${RS_ARGS[@]}"}"
rs_init
VER="${1:?usage: release-stage.sh <version e.g. 0.26.0> [--only repos]}"
case "$VER" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "release-stage: '$VER' is not an X.Y.Z version" >&2; exit 2;;
esac
# CANDOR_ROOT lets the test harness point these at a FIXTURE tree instead of the real siblings.
# Without it neither script can be exercised without editing six live repos, which is why nine
# defects across 0.25 and 0.26 were found by publishing rather than by testing.
ROOT="${CANDOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DATE="$(date +%F)"
changed=0; skipped=0
say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✔\033[0m %s\n' "$*"; changed=$((changed+1)); }
same(){ printf '  \033[33m•\033[0m %s\n' "$*"; skipped=$((skipped+1)); }
die() { printf '  \033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }
# A scratch dir OUTSIDE the tree — this script refuses to stage over uncommitted work, so it must not
# create any of its own.
WSTAGE="$(mktemp -d "${TMPDIR:-/tmp}/candor-release-stage.XXXXXX")"
trap 'rm -rf "$WSTAGE"' EXIT
# ADVISORY, and it counts as neither an edit nor a skip. It was called twice by the Cargo.lock step
# and defined nowhere, so `set -uo pipefail` (no -e) printed `note: command not found` and carried on:
# the operator saw a broken script instead of the one sentence that says how to avoid a dirty lock
# refusing the release at step 0.
note(){ printf '  \033[33m•\033[0m %s\n' "$*"; }

# Refuse to stage over uncommitted work: this script rewrites ten files across SEVEN repos, and an
# interrupted run on a dirty tree is unreviewable.
#
# ALL SEVEN, and it used to be five. The loop listed the five ENGINE repos while the script also edits
# `candor/bin/candor` (UMBRELLA_VERSION) and, through `_stage_changelogs.py`, both `candor-spec`'s and the
# umbrella's CHANGELOG. So the two repos a release author is most likely to have open — the spec they just
# amended and the umbrella they are running this FROM — were the two the guard did not cover, and an
# interrupted run there left exactly the unreviewable mixture this refusal exists to prevent. The sibling
# check four lines away in `release-preflight.sh` has always looped all seven. `_stage_changelogs.py`'s own
# header says it: "the one repo the run is being made FROM is the one you forget to treat as a repo".
# THE CUT SET — the repos this run will actually WRITE TO. A scoped run does not open the others, and
# refusing over uncommitted work in a repo it never touches would make an unrelated work-in-progress
# block a patch. Family-wide this is all seven, as it has always been.
for r in $RS_SET; do
  [ -d "$ROOT/$r" ] || continue
  # A DIRECTORY IS NOT A CHECKOUT, AND THE DIFFERENCE IS INVISIBLE TO THE `-z` BELOW. `git -C <dir>
  # status --porcelain` over anything git cannot read fails to STDERR and prints NOTHING on stdout —
  # byte-identical to a real "no changes". The `-d "$ROOT/$r"` above was the whole guard, so a
  # directory that is not a checkout (an unpacked tarball, a half-finished clone, a stale copy) sailed
  # through step 0 and this run then STAGED ~19 edits into it, unversioned and unrevertable.
  # `git -C … rev-parse --git-dir` is the authority; `-d "$ROOT/$r/.git"` is not, because a git
  # worktree's `.git` is a FILE. The `continue` above is kept deliberately: a repo that is ABSENT is
  # caught downstream by `sub()`'s "missing file", while one that is PRESENT and unreadable is not.
  git -C "$ROOT/$r" rev-parse --git-dir >/dev/null 2>&1 \
    || die "$r at $ROOT/$r is not a git checkout — 'no changes' from a tree git cannot read is indistinguishable from a clean one, and this run is about to write to it"
  [ -z "$(git -C "$ROOT/$r" status --porcelain)" ] || die "$r has uncommitted changes — commit or stash first"
done
rs_is_full || printf '  \033[33m•\033[0m %s\n' "SCOPED: staging $RS_SET only — every other repo keeps the version it last published"

# sub <file> <python-regex> <replacement>  — exactly one match required, else fail loudly.
sub() {
  local f="$ROOT/$1" pat="$2" rep="$3"
  [ -f "$f" ] || die "missing file: $1"
  python3 - "$f" "$pat" "$rep" <<'PY' || die "edit failed: $1 ($2)"
import re, sys
f, pat, rep = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(f).read()
new, n = re.subn(pat, rep, s, count=0)
if n == 0:
    # the pattern found nothing at all — either the site moved or the file is not what we think.
    print("NOMATCH"); raise SystemExit(0)
if new == s:
    # MATCHED BUT UNCHANGED. The callers' patterns match ANY version, not the old one, so a re-run
    # rewrites every site with identical bytes and used to report them as edits — this script's own
    # header claims "re-running is a no-op that reports already at", and it was not true. A run that
    # reports 18 edits when nothing moved hides the one release where something did.
    print("SAME"); raise SystemExit(0)
open(f, "w").write(new); print("OK %d" % n)
PY
}
# OUT OF SCOPE is neither an edit nor an already-current skip, so it gets its own verb and its own
# counter. Folding it into `same` would inflate "already-current" with sites this run never looked at —
# the same distinction `sub()`'s SAME branch exists to draw, one level up.
oosn=0
oos() { printf '  \033[33m⊘\033[0m %s\n' "$*"; oosn=$((oosn+1)); }
# Generated changelog stubs, re-printed at the end. A line in the middle of ~19 edits is a line that gets
# scrolled past, and these are the only edits that assert something about a repo rather than moving a
# version string — "no changes recorded here" is a claim, and it has to be read before it is committed.
stubs=""
bump() { # $1 label ; $2 file ; $3 regex with (?P<v>) ; $4 replacement template ; $5 owning repo
  if [ "$#" -ge 5 ] && ! rs_in_set "$5"; then oos "$1: $5 is not in this cut — left at the version it last published   ($2)"; return; fi
  local out; out="$(sub "$2" "$3" "$4")"
  case "$out" in
    OK*)      ok "$1 → $VER   ($2)";;
    SAME)     same "$1 already at $VER   ($2)";;
    NOMATCH)  same "$1: pattern found no match — did the site move?   ($2)";;
    *)        die "$1: unexpected result '$out'";;
  esac
}

say "1. self-declared build versions"
bump "agents VERSION" "candor-agents/candor_agents/scan.py"          'VERSION = "agents-[0-9]+\.[0-9]+\.[0-9]+"'   "VERSION = \"agents-$VER\"" candor-agents
bump "agents pyproject" "candor-agents/pyproject.toml"               '(?m)^version = "[0-9]+\.[0-9]+\.[0-9]+"'     "version = \"$VER\"" candor-agents
bump "swift engine" "candor-swift/Sources/candor-swift/main.swift"   'engineVersion = "candor-swift-[0-9]+\.[0-9]+\.[0-9]+"' "engineVersion = \"candor-swift-$VER\"" candor-swift
bump "ts package.json" "candor-ts/package.json"                      '"version": "[0-9]+\.[0-9]+\.[0-9]+"'        "\"version\": \"$VER\"" candor-ts
bump "java gradle" "candor-java/build.gradle.kts"                        '(?m)^version = "[0-9]+\.[0-9]+\.[0-9]+"'    "version = \"$VER\"" candor-java
# candor-java's README repeats the build version in its `## Status` line, and nothing staged it: every
# bump edited the SPEC number on that line and left the version, so it read `v0.19.x` for NINE releases
# before a review noticed. candor-java/test/smoke.sh now GATES it (derived from build.gradle.kts), which
# is what turns forgetting it into a red CI rather than a lie in the README — but the gate fired on this
# script's own output first, so stage it here too.
bump "java README status" "candor-java/README.md"                    '## Status: beta \(v[0-9]+\.[0-9]+\.[0-9]+'  "## Status: beta (v$VER" candor-java
# THE UMBRELLA IS THE SEVENTH REPO AND THIS SCRIPT KEPT FORGETTING IT. `UMBRELLA_VERSION` was staged by
# nothing and checked by preflight [4] not at all, so on 0.26 the umbrella declared 0.25.0 while everything
# around it moved — caught only by `update-candor.sh` refusing the Homebrew step. Not cosmetic: the tap
# formula's sha256 is computed over the TAG's tarball, so a tag whose bin/candor still says the old version
# ships a brew umbrella that ALSO sets the old ENGINE_PIN — i.e. fetches last release's engines. That is
# verbatim the 0.18-engines-under-a-0.23-umbrella failure ENGINE_PIN's own comment records.
#
# ENGINE_PIN is deliberately NOT bumped here: it names a PUBLISHED release, so it moves after one exists
# (release.sh step 6). UMBRELLA_VERSION names THIS commit, so it moves with the bump.
bump "umbrella version" "candor/bin/candor"                             '(?m)^UMBRELLA_VERSION="[0-9]+\.[0-9]+\.[0-9]+"' "UMBRELLA_VERSION=\"$VER\"" candor

say "2. rust crate versions"
for c in candor-report candor-classify candor-scan candor-query; do
  bump "$c" "candor-rust/crates/$c/Cargo.toml" '(?m)^version = "[0-9]+\.[0-9]+\.[0-9]+"' "version = \"$VER\"" candor-rust
done

say "3. rust INTER-CRATE deps (the 0.25 failure: cargo resolves these from crates.io and dies mid-sequence)"
for f in candor-rust/Cargo.toml candor-rust/crates/candor-classify/Cargo.toml \
         candor-rust/crates/candor-scan/Cargo.toml candor-rust/crates/candor-query/Cargo.toml; do
  bump "$(basename "$(dirname "$f")")/$(basename "$f")" "$f" \
    '(candor-(?:report|classify|scan|query) = \{ path = "[^"]+", version = ")[0-9]+\.[0-9]+\.[0-9]+(")' "\\g<1>$VER\\g<2>" candor-rust
done

# ── 3b. Cargo.lock — it records the workspace members' versions, so bumping the manifests without it
# leaves the lock stale. Nothing here noticed, because the FIRST cargo invocation afterwards rewrites it
# — and if that happens after the staging commit (running the suites, or preflight's own conformance
# build), `release.sh` step 0 then refuses with "candor-rust has uncommitted changes" AFTER the operator
# has already reviewed and committed the staged diff. Order-dependent friction, so: refresh it here,
# while the tree is being staged. `--workspace` touches only the member versions, never dependency
# resolution, so this cannot quietly upgrade a third-party crate as part of a release.
# JUDGED ON THE FILE, not on cargo's exit code. `cargo update` succeeds on a no-op ("Locking 0 packages")
# and leaves the lock byte-identical — reporting that as an edit breaks the header's "re-running with the
# same version is a no-op" promise and erases exactly the distinction `sub()`'s SAME branch was added to
# draw: "a run that reports 18 edits when nothing moved hides the one release where something did".
LOCK="$ROOT/candor-rust/Cargo.lock"
if ! rs_in_set candor-rust; then
  oos "rust Cargo.lock: candor-rust is not in this cut — no manifest moved, so the lock is already current"
elif ! command -v cargo >/dev/null 2>&1; then
  note "cargo not on PATH — Cargo.lock not refreshed; run \`cargo update --workspace\` in candor-rust before committing, or step 0 of release.sh will refuse on a dirty lock"
elif [ ! -f "$ROOT/candor-rust/Cargo.toml" ]; then
  note "no candor-rust/Cargo.toml — Cargo.lock not refreshed"
else
  # `cmp` ON A COPY, NOT A HASH. The first version compared `shasum` output, and if shasum were missing
  # or failing BOTH substitutions came back empty — equal — so every run reported SAME, including one
  # that created the lock from nothing. That is the A6 under-report inverted, arriving through the tool
  # meant to fix it, and all three new harness rows passed against it (they read the stager's prose, and
  # the prose was the SAME line). cmp is POSIX, needs no second tool, and an unreadable copy fails LOUD.
  before="$WSTAGE/Cargo.lock.before"; rm -f "$before"
  [ -f "$LOCK" ] && { cp "$LOCK" "$before" || die "cannot snapshot $LOCK — refusing to guess whether it changed"; }
  if ( cd "$ROOT/candor-rust" && cargo update --workspace --offline >/dev/null 2>&1 ); then
    if [ -f "$before" ] && [ -f "$LOCK" ] && cmp -s "$before" "$LOCK"; then same "rust Cargo.lock already at $VER"
    elif [ ! -f "$before" ] && [ ! -f "$LOCK" ]; then same "rust Cargo.lock absent (no workspace lock to refresh)"
    else ok "rust Cargo.lock → $VER"; fi
  else
    note "cargo update --workspace failed (empty workspace? offline?) — run it in candor-rust before committing, or step 0 of release.sh will refuse on a dirty lock"
  fi
fi

say "4. CHANGELOGs — rename the bare Unreleased heading to the version being cut"
# The 0.25 release left FOUR changelogs with shipped work still under `## Unreleased` (the v0.25.0 tag
# contains the commits that wrote it). preflight [9] catches that now; this performs the fix.
# One python invocation for all repos: a heredoc nested inside `$(...)` is a parse hazard, and the loop
# reads more clearly on the python side anyway.
# shellcheck disable=SC2097,SC2098  # these are ENV for the python3 child, not assignments this shell
# reads back — which is exactly the intent.
cl_out="$(ROOT="$ROOT" VER="$VER" DATE="$DATE" RS_SET="$RS_SET" python3 "$ROOT/candor/bin/_stage_changelogs.py")" \
  || die "changelog staging failed: $cl_out"
while IFS= read -r line; do
  case "$line" in
    OK*)      ok "${line#OK }";;
    # OOS — a repo outside the cut set. Its `## Unreleased` is staged work for the NEXT release of that
    # repo, and renaming it to this version would label work as shipped that this cut does not publish.
    OOS*)     oos "${line#OOS }";;
    # `FOLD` is what the helper prints when a version heading ALREADY EXISTS and the stranded
    # `## Unreleased` body is folded into it. Adding that verb to the helper without adding it here made
    # the FIRST fold line hit the `die` arm below — so the canonical staging run for 0.27 exited RED over
    # edits that were already correctly on disk (python runs before this loop reads a word of its output).
    # The 55-assertion harness could not see it: its fold rows invoke `_stage_changelogs.py` directly and
    # never this wrapper. A test that bypasses the integration point is a test of the wrong thing.
    FOLD*)    ok "${line#FOLD }";;
    # `STUB` is what the helper prints when `## Unreleased` was EMPTY and the version has no section of
    # its own: it writes a "build bump only — no changes recorded" entry rather than leaving the version
    # unlabelled, because an absent section used to make `release.sh` republish the PREVIOUS version's
    # notes under the new tag. Counted as an EDIT (it is one) and re-printed below the summary, because
    # it is the one edit in this script that makes a CLAIM about the repo rather than moving a number.
    # Adding a verb here without adding it to the `case` is how the 0.27 staging run exited RED over
    # edits already correctly on disk — the `*) die` arm below is not a hypothetical.
    STUB*)    ok "${line#STUB }"; stubs="$stubs${stubs:+$'\n'}  ${line#STUB }";;
    SAME*)    same "${line#SAME }";;
    "")       ;;
    *)        die "changelog: $line";;
  esac
done <<< "$cl_out"

echo
if rs_is_full; then echo "release-stage: $changed edit(s), $skipped already-current."
else echo "release-stage: $changed edit(s), $skipped already-current, $oosn out of scope (cut set: $RS_SET)."; fi
if [ -n "$stubs" ]; then
  printf '\n\033[1m  GENERATED CHANGELOG STUBS — READ THESE BEFORE COMMITTING\033[0m\n'
  printf '%s\n' "$stubs"
  echo "  Each says \"no changes recorded in this repo for this release\". That is the honest reading of an"
  echo "  empty \`## Unreleased\`, and it is what makes a version-only bump publishable — but it is a CLAIM."
  echo "  Rewrite each in its repo's own voice, or, if the repo really did change, write the entry the"
  echo "  release deserves. (\`release-preflight.sh\` [5b] is the check that asks whether source moved"
  echo "  without the changelog; a stub does not answer it.)"
fi
echo "NOTHING is committed, tagged or pushed — review the diffs, then:"
if rs_is_full; then echo "    bash bin/release-preflight.sh <spec> $VER      # judges what this staged"
else echo "    bash bin/release-preflight.sh <spec> $VER --only $(printf '%s' "$RS_SET" | tr ' ' ',')   # judges what this staged"; fi
echo '  spec DECLARATIONS are deliberately untouched (a floor bump is a separate, earlier decision).'
# ⟨0.29⟩ the two IDE pins joined preflight [3] and this line did not move with them, so the operator
# instruction enumerated a SUBSET of what the gate now blocks on — the reader follows this, the gate
# fails on something it never mentioned.
echo "  cross-repo PINS (adopt/, jbang, ENGINE_PIN, the vscode + jetbrains candorTs/candorJava pins) are"
echo "  updated AFTER the release exists — preflight [3] enumerates all of them."
