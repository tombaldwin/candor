#!/usr/bin/env bash
# release-stage.sh — perform the MECHANICAL half of staging a release, so a human does not.
#
#   bash bin/release-stage.sh 0.26.0
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
VER="${1:?usage: release-stage.sh <version e.g. 0.26.0>}"
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

# Refuse to stage over uncommitted work: this script rewrites ten files across six repos, and an
# interrupted run on a dirty tree is unreviewable.
for r in candor-rust candor-java candor-ts candor-swift candor-agents; do
  [ -d "$ROOT/$r" ] || continue
  [ -z "$(git -C "$ROOT/$r" status --porcelain)" ] || die "$r has uncommitted changes — commit or stash first"
done

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
bump() { # $1 label ; $2 file ; $3 regex with (?P<v>) ; $4 replacement template
  local out; out="$(sub "$2" "$3" "$4")"
  case "$out" in
    OK*)      ok "$1 → $VER   ($2)";;
    SAME)     same "$1 already at $VER   ($2)";;
    NOMATCH)  same "$1: pattern found no match — did the site move?   ($2)";;
    *)        die "$1: unexpected result '$out'";;
  esac
}

say "1. self-declared build versions"
bump "agents VERSION" "candor-agents/candor_agents/scan.py"          'VERSION = "agents-[0-9]+\.[0-9]+\.[0-9]+"'   "VERSION = \"agents-$VER\""
bump "agents pyproject" "candor-agents/pyproject.toml"               '(?m)^version = "[0-9]+\.[0-9]+\.[0-9]+"'     "version = \"$VER\""
bump "swift engine" "candor-swift/Sources/candor-swift/main.swift"   'engineVersion = "candor-swift-[0-9]+\.[0-9]+\.[0-9]+"' "engineVersion = \"candor-swift-$VER\""
bump "ts package.json" "candor-ts/package.json"                      '"version": "[0-9]+\.[0-9]+\.[0-9]+"'        "\"version\": \"$VER\""
bump "java gradle" "candor-java/build.gradle.kts"                        '(?m)^version = "[0-9]+\.[0-9]+\.[0-9]+"'    "version = \"$VER\""
# candor-java's README repeats the build version in its `## Status` line, and nothing staged it: every
# bump edited the SPEC number on that line and left the version, so it read `v0.19.x` for NINE releases
# before a review noticed. candor-java/test/smoke.sh now GATES it (derived from build.gradle.kts), which
# is what turns forgetting it into a red CI rather than a lie in the README — but the gate fired on this
# script's own output first, so stage it here too.
bump "java README status" "candor-java/README.md"                    '## Status: beta \(v[0-9]+\.[0-9]+\.[0-9]+'  "## Status: beta (v$VER"
# THE UMBRELLA IS THE SEVENTH REPO AND THIS SCRIPT KEPT FORGETTING IT. `UMBRELLA_VERSION` was staged by
# nothing and checked by preflight [4] not at all, so on 0.26 the umbrella declared 0.25.0 while everything
# around it moved — caught only by `update-candor.sh` refusing the Homebrew step. Not cosmetic: the tap
# formula's sha256 is computed over the TAG's tarball, so a tag whose bin/candor still says the old version
# ships a brew umbrella that ALSO sets the old ENGINE_PIN — i.e. fetches last release's engines. That is
# verbatim the 0.18-engines-under-a-0.23-umbrella failure ENGINE_PIN's own comment records.
#
# ENGINE_PIN is deliberately NOT bumped here: it names a PUBLISHED release, so it moves after one exists
# (release.sh step 6). UMBRELLA_VERSION names THIS commit, so it moves with the bump.
bump "umbrella version" "candor/bin/candor"                             '(?m)^UMBRELLA_VERSION="[0-9]+\.[0-9]+\.[0-9]+"' "UMBRELLA_VERSION=\"$VER\""

say "2. rust crate versions"
for c in candor-report candor-classify candor-scan candor-query; do
  bump "$c" "candor-rust/crates/$c/Cargo.toml" '(?m)^version = "[0-9]+\.[0-9]+\.[0-9]+"' "version = \"$VER\""
done

say "3. rust INTER-CRATE deps (the 0.25 failure: cargo resolves these from crates.io and dies mid-sequence)"
for f in candor-rust/Cargo.toml candor-rust/crates/candor-classify/Cargo.toml \
         candor-rust/crates/candor-scan/Cargo.toml candor-rust/crates/candor-query/Cargo.toml; do
  bump "$(basename "$(dirname "$f")")/$(basename "$f")" "$f" \
    '(candor-(?:report|classify|scan|query) = \{ path = "[^"]+", version = ")[0-9]+\.[0-9]+\.[0-9]+(")' "\\g<1>$VER\\g<2>"
done

# ── 3b. Cargo.lock — it records the workspace members' versions, so bumping the manifests without it
# leaves the lock stale. Nothing here noticed, because the FIRST cargo invocation afterwards rewrites it
# — and if that happens after the staging commit (running the suites, or preflight's own conformance
# build), `release.sh` step 0 then refuses with "candor-rust has uncommitted changes" AFTER the operator
# has already reviewed and committed the staged diff. Order-dependent friction, so: refresh it here,
# while the tree is being staged. `--workspace` touches only the member versions, never dependency
# resolution, so this cannot quietly upgrade a third-party crate as part of a release.
if command -v cargo >/dev/null 2>&1 && [ -f "$ROOT/candor-rust/Cargo.toml" ]; then
  if ( cd "$ROOT/candor-rust" && cargo update --workspace --offline >/dev/null 2>&1 ); then
    ok "rust Cargo.lock refreshed to $VER"
  else
    note "cargo update --workspace failed (offline?) — run it in candor-rust before committing, or step 0 of release.sh will refuse on a dirty lock"
  fi
else
  note "cargo not on PATH — Cargo.lock not refreshed; do it before committing"
fi

say "4. CHANGELOGs — rename the bare Unreleased heading to the version being cut"
# The 0.25 release left FOUR changelogs with shipped work still under `## Unreleased` (the v0.25.0 tag
# contains the commits that wrote it). preflight [9] catches that now; this performs the fix.
# One python invocation for all repos: a heredoc nested inside `$(...)` is a parse hazard, and the loop
# reads more clearly on the python side anyway.
# shellcheck disable=SC2097,SC2098  # these are ENV for the python3 child, not assignments this shell
# reads back — which is exactly the intent.
cl_out="$(ROOT="$ROOT" VER="$VER" DATE="$DATE" python3 "$ROOT/candor/bin/_stage_changelogs.py")" \
  || die "changelog staging failed: $cl_out"
while IFS= read -r line; do
  case "$line" in
    OK*)      ok "${line#OK }";;
    # `FOLD` is what the helper prints when a version heading ALREADY EXISTS and the stranded
    # `## Unreleased` body is folded into it. Adding that verb to the helper without adding it here made
    # the FIRST fold line hit the `die` arm below — so the canonical staging run for 0.27 exited RED over
    # edits that were already correctly on disk (python runs before this loop reads a word of its output).
    # The 55-assertion harness could not see it: its fold rows invoke `_stage_changelogs.py` directly and
    # never this wrapper. A test that bypasses the integration point is a test of the wrong thing.
    FOLD*)    ok "${line#FOLD }";;
    SAME*)    same "${line#SAME }";;
    "")       ;;
    *)        die "changelog: $line";;
  esac
done <<< "$cl_out"

echo
echo "release-stage: $changed edit(s), $skipped already-current."
echo "NOTHING is committed, tagged or pushed — review the diffs, then:"
echo "    bash bin/release-preflight.sh <spec> $VER      # judges what this staged"
echo '  spec DECLARATIONS are deliberately untouched (a floor bump is a separate, earlier decision).'
echo "  cross-repo PINS (adopt/, jbang, ENGINE_PIN) are updated AFTER the release exists — preflight [3]."
