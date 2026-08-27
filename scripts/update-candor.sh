#!/usr/bin/env bash
# update-candor.sh — cut a candor umbrella release and update the Homebrew formula, in one command.
#
#   scripts/update-candor.sh v0.16.0
#
# It:
#   1. checks the tag matches bin/candor's UMBRELLA_VERSION (they must agree — the formula version and
#      the engine line `candor update` fetches are the same number),
#   2. tags the release and pushes it,
#   3. cuts a GitHub release (every tag gets a `gh release` — the family rule),
#   4. downloads GitHub's generated source tarball, computes its SHA-256,
#   5. writes the tap formula's url + sha256, and commits + pushes the tap.
#
# Run from the umbrella repo root with a clean tree at the commit you want released.
set -euo pipefail

TAG="${1:?usage: update-candor.sh vX.Y.Z}"
VER="${TAG#v}"
REPO="tombaldwin/candor"
TAP="${CANDOR_TAP:-$HOME/git/homebrew-tap}"
FORMULA="$TAP/Formula/candor.rb"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

# 1. the tag and UMBRELLA_VERSION must agree
UV="$(sed -n 's/^UMBRELLA_VERSION="\([^"]*\)".*/\1/p' bin/candor)"
[ "$UV" = "$VER" ] || { echo "refusing: bin/candor UMBRELLA_VERSION=$UV but tag is $TAG — bump them together."; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "refusing: working tree is dirty — commit first."; exit 1; }
[ -f "$FORMULA" ] || { echo "no formula at $FORMULA (set CANDOR_TAP)."; exit 1; }

# 2. tag + push — IDEMPOTENT, because release.sh now cuts `v$VER` itself before calling this. Creating it
# unconditionally is what produced two tags per release; skipping is what lets this be called either as
# part of release.sh or standalone for a CLI-only umbrella bump.
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "tag $TAG already exists — reusing it"
else
  git tag -a "$TAG" -m "candor umbrella $VER — the one-command front door; manages the engines"
  git push origin "$TAG"
fi

# 3. gh release — same reason
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "release $TAG already exists — reusing it"
else
gh release create "$TAG" -R "$REPO" --title "candor $VER (umbrella)" --notes \
"The umbrella dispatcher — one \`candor\` command across every language. Install it and run \`candor update\` to fetch the engines (the flagship JVM engine as a native binary, no JVM needed).

Install: \`brew install tombaldwin/tap/candor\`"
fi

# 4. SHA-256 of GitHub's generated source tarball
URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
echo "fetching $URL for the checksum…"
SHA="$(curl -fsSL "$URL" | shasum -a 256 | awk '{print $1}')"
[ -n "$SHA" ] || { echo "could not checksum the release tarball."; exit 1; }

# 5. write + commit + push the formula. SINGLE-quote the perl so bash leaves $ENV{...} to perl, and
# pass url/sha through the environment (a double-quoted "$ENV{URL}" would make bash expand the unset
# $ENV — fatal under set -u — and never reach perl).
URL="$URL" perl -0pi -e 's{url "[^"]*"}{url "$ENV{URL}"}' "$FORMULA"
SHA="$SHA" perl -0pi -e 's{sha256 "[0-9a-f]{64}"}{sha256 "$ENV{SHA}"}' "$FORMULA"
( cd "$TAP" && git add Formula/candor.rb && git commit -m "candor $VER" )

# THE TAP IS SHARED — it carries every other formula this maintainer publishes, so a push landing
# between our last fetch and our push is the NORMAL case, not an error. Measured twice (0.33.1, and once
# before): an unrelated formula bump rejected this push AFTER the umbrella tag + GitHub release above had
# already been cut — i.e. after the irreversible steps — turning a routine, non-conflicting race into a
# failed release run that had already published. Rebase-and-retry, bounded, so the ordinary case recovers
# on its own; a REAL conflict (this maintainer's own candor.rb edit racing itself, not a different
# formula file) must still fail loudly rather than retry forever or drop the update silently — that is
# the over-charge control on this fix.
TAP_PUSH_MAX=5
tap_push_attempt=1
tap_pushed=0
while [ "$tap_push_attempt" -le "$TAP_PUSH_MAX" ]; do
  if ( cd "$TAP" && git push ) 2>/tmp/candor-tap-push.err; then
    tap_pushed=1
    break
  fi
  if ! grep -qiE 'rejected|fetch first|non-fast-forward|stale info' /tmp/candor-tap-push.err; then
    # Not the shared-repo race this loop exists for (auth, network, no remote, …) — surface it once and
    # stop; retrying a failure this loop cannot fix would just burn attempts and delay the real message.
    cat /tmp/candor-tap-push.err >&2
    break
  fi
  echo "tap push rejected (attempt $tap_push_attempt/$TAP_PUSH_MAX) — the tap is shared; pulling --rebase and retrying…" >&2
  if ( cd "$TAP" && git pull --rebase ) >/tmp/candor-tap-rebase.out 2>&1; then
    :
  else
    cat /tmp/candor-tap-rebase.out >&2
    ( cd "$TAP" && git rebase --abort ) >/dev/null 2>&1 || true
    echo "tap rebase hit a REAL conflict in $FORMULA — not retrying further. The commit is still local; resolve by hand in $TAP, then push." >&2
    break
  fi
  tap_push_attempt=$((tap_push_attempt + 1))
done

if [ "$tap_pushed" != 1 ]; then
  echo "could not push the Homebrew tap after $tap_push_attempt attempt(s)." >&2
  echo "the umbrella release + tag for $VER already exist (that part is done and irreversible) — only the tap push is unresolved." >&2
  echo "fix by hand: cd $TAP && git status   (a clean tree with an unpushed commit means: git pull --rebase && git push;" >&2
  echo "             a conflict in Formula/candor.rb means: resolve it, git rebase --continue, then git push)" >&2
  exit 1
fi

echo "done: candor $VER released and the tap updated. Verify: brew install tombaldwin/tap/candor"
