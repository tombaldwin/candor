#!/usr/bin/env bash
# release-preflight — the automated "always check before publishing" gate for the candor family.
#
# Run from anywhere; it inspects the sibling repos (../candor-spec, ../candor-rust, …). It catches the
# release-readiness classes that have actually bitten us: a declared spec that disagrees across engines, a
# STALE spec/version string left in a CI-only test script or doc after a bump (the kind `cargo test` /
# `npm test` don't run, so they only fail in CI), and cross-repo release PINS (adopt/, jbang) still pointing
# at the previous release. It does NOT replace conformance or CI — run those too — it replaces the manual
# grep sweep that keeps finding stragglers one repo at a time.
#
#   bash bin/release-preflight.sh            # derive the floor from the engines, check consistency
#   bash bin/release-preflight.sh 0.10 0.10.0  # also assert the floor spec / release version explicitly
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # the dir holding candor-* siblings
WANT_SPEC="${1:-}"     # optional: assert the floor is exactly this (e.g. 0.10)
WANT_VER="${2:-}"      # optional: assert the release version is this (e.g. 0.10.0) for the cross-repo pins
fail=0
note() { echo "  $*"; }
bad()  { echo "  ✘ $*"; fail=1; }
ok()   { echo "  ✔ $*"; }

# --- 1. every engine DECLARES the same spec (the contract floor) ----------------------------------------
echo "[1] declared spec is uniform across engines"
declare -a specs=()
grab() { # $1 label ; $2 file ; $3 regex capturing the version
  local f="$ROOT/$2"
  [ -f "$f" ] || { bad "$1: missing $2"; return; }
  local v; v="$(grep -oE "$3" "$f" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  [ -n "$v" ] || { bad "$1: no spec string in $2"; return; }
  note "$1: spec $v"; specs+=("$v")
}
grab "rust " "candor-rust/crates/candor-report/src/lib.rs" 'SPEC_VERSION[^0-9]*[0-9]+\.[0-9]+'
grab "ts   " "candor-ts/query.mjs"                          'SPEC_VERSION *= *"[0-9]+\.[0-9]+'
grab "java " "candor-java/src/main/java/io/poly/candor/Candor.java" 'SPEC_VERSION *= *"[0-9]+\.[0-9]+'
grab "swift" "candor-swift/Sources/candor-swift/main.swift" 'specVersion *= *"[0-9]+\.[0-9]+'
grab "agent" "candor-agents/candor_agents/scan.py"          'SPEC *= *"[0-9]+\.[0-9]+'
grab "spec " "candor-spec/SPEC.md"                          'Version [0-9]+\.[0-9]+'
FLOOR=""
if [ "${#specs[@]}" -gt 0 ]; then
  FLOOR="$(printf '%s\n' "${specs[@]}" | sort -u)"
  if [ "$(printf '%s\n' "$FLOOR" | grep -c .)" -eq 1 ]; then ok "all declare spec $FLOOR"
  else bad "engines DISAGREE on the declared spec: $(echo $FLOOR)"; FLOOR=""; fi
fi
[ -n "$WANT_SPEC" ] && { [ "$FLOOR" = "$WANT_SPEC" ] && ok "floor == requested $WANT_SPEC" || bad "floor '$FLOOR' != requested '$WANT_SPEC'"; }

# --- 2. no LEFTOVER PRIOR-FLOOR spec string in shipped code / tests / CI scripts -------------------------
# The bug class: a bump moves the SPEC_VERSION constant but misses a `spec 0.9` baked into a CI-only script
# (smoke.sh / integration.sh) or a golden. The precise signature is a leftover string of the PRIOR floor
# (0.10 → 0.9) — distinct from intentionally-OLDER fixtures (a SARIF converter tested against a spec-0.7
# envelope) and CHANGELOG/design history, which are NOT flagged. Excludes vendor/build dirs, CHANGELOG,
# narrative docs, ⟨X⟩ era markers.
PRIOR=""
if [ -n "$FLOOR" ]; then
  maj="${FLOOR%%.*}"; min="${FLOOR#*.}"
  [ "$min" -gt 0 ] 2>/dev/null && PRIOR="$maj.$((min-1))"
fi
echo "[2] no leftover prior-floor (${PRIOR:-?}) spec strings — the bump-miss signature"
if [ -n "$PRIOR" ]; then
  strays="$(cd "$ROOT" && grep -rInE "spec[ :\"]+${PRIOR//./\\.}([^0-9]|$)" \
      --exclude-dir=target --exclude-dir=node_modules --exclude-dir=.build --exclude-dir=build \
      --exclude-dir=.git --exclude-dir=eval --exclude-dir=.gradle --exclude-dir=docs \
      --exclude='CHANGELOG*' --exclude=BACKLOG.md --exclude='*DESIGN*.md' --exclude='*-LOG.md' \
      --exclude=release-preflight.sh \
      candor-spec candor-rust candor-ts candor-java candor-swift candor-agents candor 2>/dev/null \
    | grep -vE '⟨[0-9]' )"
  if [ -z "$strays" ]; then ok "no leftover 'spec $PRIOR' strings"
  else bad "leftover 'spec $PRIOR' (a bump missed these — they only fail in CI):"; echo "$strays" | sed 's/^/      /'; fi
else note "(no prior floor to check)"; fi

# --- 3. cross-repo RELEASE PINS point at the current release --------------------------------------------
# adopt/ drops a pinned engine into a user's repo; jbang points at a release jar. A bump must move these
# (only AFTER the release exists — the URLs must resolve). Checked against WANT_VER when given.
echo "[3] cross-repo release pins"
checkpin() { # $1 label ; $2 file ; $3 grep pattern to show
  local f="$ROOT/$2"; [ -f "$f" ] || { note "$1: (no $2)"; return; }
  local line; line="$(grep -nE "$3" "$f" | head -1)"
  [ -n "$line" ] && note "$1: $line" || note "$1: (pin not found)"
  if [ -n "$WANT_VER" ] && [ -n "$line" ] && ! echo "$line" | grep -qF "$WANT_VER"; then
    bad "$1: pin does not reference $WANT_VER (update AFTER the release is published)"
  fi
}
checkpin "adopt java  " "candor/adopt/candor.yml"        'CANDOR_JAVA_VERSION:[[:space:]]*[0-9]'
checkpin "adopt agents" "candor/adopt/candor-digest.yml" 'candor-agents@'
checkpin "jbang       " "candor-java/jbang-catalog.json" 'releases/download'

echo
if [ "$fail" = 0 ]; then echo "release-preflight: OK${FLOOR:+ (floor $FLOOR)}"; else echo "release-preflight: $fail check(s) FAILED — resolve before publishing"; fi
exit "$fail"
