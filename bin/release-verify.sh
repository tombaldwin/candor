#!/usr/bin/env bash
# release-verify — the post-publish smoke: confirm the PUBLISHED artifacts (crates.io, npm, GitHub releases)
# actually carry the version just shipped, and that a fresh `npx` of the published package reports the spec.
# Run AFTER publishing.   bash bin/release-verify.sh 0.10 0.10.0
set -u
SPEC="${1:?usage: release-verify.sh <spec> <ver>   e.g. 0.10 0.10.0}"
VER="${2:?usage: release-verify.sh <spec> <ver>}"
ROOT_C="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # the dir holding candor-* siblings
UA="candor-release-verify (tom@polymorphism.co.uk)"   # crates.io 403s a UA-less request
fail=0; ok() { echo "  ✔ $*"; }
# INCREMENT, do not assign — this was `fail=1`, so the summary reported one failure no matter how many
# fired. Same defect release-preflight carried. The number is what tells you whether the last fix helped.
bad() { echo "  ✘ $*"; fail=$((fail + 1)); }
note() { echo "  · $*"; }

echo "[crates.io] the four crates at $VER"
for c in candor-report candor-classify candor-query candor-scan; do
  v=$(curl -sSL -H "User-Agent: $UA" "https://crates.io/api/v1/crates/$c" 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["crate"]["max_version"])' 2>/dev/null)
  [ "$v" = "$VER" ] && ok "$c $v" || bad "$c: max_version '${v:-?}' != $VER"
done

echo "[npm] candor-ts at $VER"
v=$(npm view candor-ts version 2>/dev/null)
[ "$v" = "$VER" ] && ok "candor-ts $v" || bad "candor-ts: npm version '${v:-?}' != $VER"

echo "[gh releases] spec v$SPEC · engines v$VER"
# candor-ts and the umbrella were MISSING from this list until 2026-08-01 — so a release could be declared
# live with neither cut, and on 0.24 candor-spec itself was found untagged only because it WAS listed here.
# candor-spec is tagged at the SPEC version (`v0.25`), not the engine build (`v0.25.0`) — the spec has no
# patch component, and `release.sh` cuts it as `rel candor-spec "v$SPEC"`. This line said `v$VER` for both,
# so the VERIFIER and the PUBLISHER disagreed on the tag name. It never surfaced at 0.24 only because the
# 0.24 cleanup hand-created a `v0.24.0` spec tag — the very thing the verifier was looking for — which
# masked the mismatch and left two tag schemes in the history (v0.25, v0.24.0, v0.23, v0.21.0 …).
for r in "candor-spec:v$SPEC" "candor-rust:v$VER" "candor-java:v$VER" "candor-swift:v$VER" \
         "candor-agents:v$VER" "candor-ts:v$VER" "candor:v$VER"; do
  repo="${r%%:*}"; tag="${r##*:}"
  got=$(gh release view "$tag" -R "tombaldwin/$repo" --json tagName -q .tagName 2>/dev/null)
  [ "$got" = "$tag" ] && ok "$repo $got" || bad "$repo: release '${got:-missing}' != $tag"
done

# --- the pinned DOWNLOAD URLS actually resolve --------------------------------------------------------
# Added 2026-08-01, after the 0.24 release shipped with `jbang-catalog.json` and `bin/candor` pinned at
# v0.24.0 while the candor-java GitHub release did not exist — so every `candor update` and every jbang
# invocation got a 404 for the JVM engine. `release-preflight [3]` was GREEN throughout: it checks that the
# pin SAYS the right version, which is not the same question as whether the thing it names is there.
# A pin naming a URL is not the URL existing. Resolve the artifact, never just the string.
echo "[artifacts] the pinned download URLs resolve"
declare -a urls=()
# derive from the pin files rather than hardcoding, so this tracks the pins instead of drifting beside them
jb="$ROOT_C/candor-java/jbang-catalog.json"
[ -f "$jb" ] && while read -r u; do urls+=("$u"); done < <(grep -oE 'https://github\.com/[^"]+/releases/download/[^"]+' "$jb")
# what `candor update` fetches for the JVM front door (bin/candor builds these from $ENGINE_PIN)
for a in "candor-java-$VER-all.jar" candor-linux-x64 candor-macos-arm64; do
  urls+=("https://github.com/tombaldwin/candor-java/releases/download/v$VER/$a")
done
# candor-swift's binary. THE GAP THIS CLOSES: every candor-swift release through v0.26.0 had ZERO assets
# — the workflow built, tested, smoked and cut the release, then attached nothing — and this verifier
# passed every one of them, because the release loop above only asks whether the RELEASE EXISTS. That is
# exactly the mistake the comment above warns about, made about a different repo: a release is not an
# installable artifact. The visible cost was `candor update` telling a Mac user to install a Swift
# toolchain and build from source, for the engine that owns the privacy manifest. Assets begin at 0.27;
# below that their absence is history rather than a regression, so it is noted and not failed.
case "$VER" in
  0.1?.*|0.2[0-6].*) note "candor-swift: no binary asset expected before 0.27 (its workflow attached none)";;
  *) urls+=("https://github.com/tombaldwin/candor-swift/releases/download/v$VER/candor-swift-macos-arm64");;
esac
if [ "${#urls[@]}" -eq 0 ]; then bad "no pinned download URLs found — the check cannot have passed"; fi
for u in $(printf '%s\n' "${urls[@]}" | sort -u); do
  # A URL derived from a pin file must ALSO name the version under verification. Checking only that it
  # RESOLVES lets a stale pin pass green: verifying 0.99.0 while jbang still points at v0.24.0 fetches a
  # real, downloadable, WRONG jar. Resolving is necessary, not sufficient — the artifact has to be the one
  # this release claims to ship.
  case "$u" in
    *"/v$VER/"*) ;;
    *) bad "pin names a different version than v$VER — $u"; continue ;;
  esac
  code=$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 45 "$u" 2>/dev/null)
  [ "$code" = "200" ] && ok "$code ${u##*/}" || bad "$code ${u##*/} — $u"
done

echo "[live smoke] npx candor-ts@$VER --version reports spec $SPEC"
out=$(npx -y "candor-ts@$VER" --version 2>/dev/null | head -1)
echo "$out" | grep -q "spec $SPEC" && ok "$out" || bad "npx reported '${out:-<none>}' (expected spec $SPEC)"

echo
[ "$fail" = 0 ] && echo "release-verify: OK — spec $SPEC / v$VER is live everywhere" || echo "release-verify: $fail check(s) FAILED"
[ "$fail" = 0 ] || exit 1   # NOT `exit "$fail"` — 256 failures would exit 0, a wrap to green
exit 0
