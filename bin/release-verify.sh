#!/usr/bin/env bash
# release-verify — the post-publish smoke: confirm the PUBLISHED artifacts (crates.io, npm, GitHub releases)
# actually carry the version just shipped, and that a fresh `npx` of the published package reports the spec.
# Run AFTER publishing.   bash bin/release-verify.sh 0.10 0.10.0
set -u
SPEC="${1:?usage: release-verify.sh <spec> <ver>   e.g. 0.10 0.10.0}"
VER="${2:?usage: release-verify.sh <spec> <ver>}"
UA="candor-release-verify (tom@polymorphism.co.uk)"   # crates.io 403s a UA-less request
fail=0; ok() { echo "  ✔ $*"; }; bad() { echo "  ✘ $*"; fail=1; }

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
for r in "candor-spec:v$VER" "candor-rust:v$VER" "candor-java:v$VER" "candor-swift:v$VER" "candor-agents:v$VER"; do
  repo="${r%%:*}"; tag="${r##*:}"
  got=$(gh release view "$tag" -R "tombaldwin/$repo" --json tagName -q .tagName 2>/dev/null)
  [ "$got" = "$tag" ] && ok "$repo $got" || bad "$repo: release '${got:-missing}' != $tag"
done

echo "[live smoke] npx candor-ts@$VER --version reports spec $SPEC"
out=$(npx -y "candor-ts@$VER" --version 2>/dev/null | head -1)
echo "$out" | grep -q "spec $SPEC" && ok "$out" || bad "npx reported '${out:-<none>}' (expected spec $SPEC)"

echo
[ "$fail" = 0 ] && echo "release-verify: OK — spec $SPEC / v$VER is live everywhere" || echo "release-verify: FAILED"
exit "$fail"
