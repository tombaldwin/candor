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
for r in "candor-spec:v$VER" "candor-rust:v$VER" "candor-java:v$VER" "candor-swift:v$VER" \
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
