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
# candor-ts has TWO SPEC_VERSION constants — query.mjs (above) AND scan.mjs, which is the one that stamps the
# REPORT ENVELOPE + gate verdict. The 0.17 bump missed scan.mjs (preflight only checked query.mjs), so reports
# shipped declaring the old floor while --version disagreed. Check both so they can never drift apart.
grab "ts-scn" "candor-ts/scan.mjs"                          'SPEC_VERSION *= *"[0-9]+\.[0-9]+'
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
    | grep -vE '⟨(spec )?[0-9]' )"
  if [ -z "$strays" ]; then ok "no leftover 'spec $PRIOR' strings"
  else bad "leftover 'spec $PRIOR' (a bump missed these — they only fail in CI):"; echo "$strays" | sed 's/^/      /'; fi

  # [2b] BARE-LITERAL spec assertions the [2] grep misses: a `]`/`,`/`==`/`as? String` between "spec" and the
  # quoted prior-floor breaks the `spec[ :"]+0.X` pattern — e.g. rust `assert_eq!(v["spec"], "0.16")`, swift
  # `XCTAssertEqual(obj?["spec"] as? String, "0.16")`. These dodge preflight AND `cargo/npm/swift test`'s
  # OWN default (they only fire the differential in CI / a `swift test` run). Signature: a line carrying BOTH
  # `spec` and the bare quoted prior-floor `"0.X"`. A legit older fixture (spec "0.7") won't match the floor.
  litstrays="$(cd "$ROOT" && grep -rIn "\"${PRIOR//./\\.}\"" \
      --exclude-dir=target --exclude-dir=node_modules --exclude-dir=.build --exclude-dir=build \
      --exclude-dir=.git --exclude-dir=.gradle --exclude-dir=docs \
      --exclude='CHANGELOG*' --exclude=BACKLOG.md --exclude='*DESIGN*.md' --exclude='*-LOG.md' \
      --exclude=release-preflight.sh \
      candor-spec candor-rust candor-ts candor-java candor-swift candor-agents candor 2>/dev/null \
    | grep -iw spec | grep -vE '⟨(spec )?[0-9]' )"
  if [ -z "$litstrays" ]; then ok "no bare-literal 'spec' == \"$PRIOR\" assertions"
  else bad "bare-literal spec assertion at the prior floor (a bump missed these; only \`*test\` catches them):"; echo "$litstrays" | sed 's/^/      /'; fi
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
# The umbrella's ENGINE_PIN is what `candor update` fetches — a SEPARATE constant from UMBRELLA_VERSION.
# It lagged at 0.18.0 through the 0.23.1 ship (brew updated the umbrella, engines stayed 0.18) → gate it:
# on an engine release it MUST equal the release version. (Umbrella-only CLI patches don't run this arg.)
checkpin "engine pin  " "candor/bin/candor"              'ENGINE_PIN='

# --- 4. self-declared BUILD versions agree (the hand-maintained constants, not the manifest) ------------
# The 0.17 bump moved pyproject/package/Cargo but missed the agents `VERSION = "agents-0.16.0"` constant
# (a SEPARATE literal in scan.py that stamps --version + the --agents header). swift's engineVersion is the
# same shape. These aren't derived from the manifest, so a bump has to touch each — assert they all agree.
echo "[4] self-declared build versions agree (hand-maintained constants vs the manifest)"
declare -a builds=()
grabver() { # $1 label ; $2 file ; $3 regex
  local f="$ROOT/$2"; [ -f "$f" ] || return
  local v; v="$(grep -oE "$3" "$f" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$v" ] && { note "$1: $v"; builds+=("$v"); }
}
grabver "agents VERSION" "candor-agents/candor_agents/scan.py"            'VERSION *= *"agents-[0-9.]+'
grabver "agents pyproj " "candor-agents/pyproject.toml"                   'version *= *"[0-9.]+'
grabver "swift engine  " "candor-swift/Sources/candor-swift/main.swift"   'engineVersion *= *"candor-swift-[0-9.]+'
grabver "ts package    " "candor-ts/package.json"                         '"version": *"[0-9.]+'
grabver "rust crate    " "candor-rust/crates/candor-query/Cargo.toml"     'version = "[0-9.]+'
# candor-java is DELIBERATELY absent, and saying so is the point: its build id is GENERATED at build time
# into `candor/build-info.properties` (build.gradle.kts) from the git hash, so it is not a hand-maintained
# constant and cannot LAG the way this check exists to catch. What it also means is that this check — and
# the `WANT_VER` assertion below — cover FOUR of the five components, and a check that silently covers a
# subset reads exactly like one that covers everything. State the coverage rather than implying it.
note "java engine   : generated at build time (git hash) — not a hand-maintained constant, not checked here"
# NOT mutual equality. A build id is PER-ENGINE by design (candor-spec §2.1 + the three-axis note): every
# engine's staleness gate compares an engine-PREFIXED string (`scan-x.y.z`, `candor-ts-x.y.z`, …), so a
# report from another engine is stale whatever the numbers say — which §2.1 intends, since you must not
# trust another engine's classifier. The only comparison a build id gates is SAME-engine, so nothing
# requires the four to match. Demanding equality also DESTROYS the information the build id exists to
# carry: if every engine moves whenever one engine changes a wire key, the version no longer tells you
# which engine changed. (Live case: candor-ts went to 0.23.2 alone because its module-unit wire key moved
# and §2.1 could not otherwise arm.) What this check is really for — a constant somebody forgot to bump —
# is caught by the WANT_VER arm below, which is exact. Without a requested version, disagreement is just
# reported.
if [ "${#builds[@]}" -gt 0 ]; then
  u="$(printf '%s\n' "${builds[@]}" | sort -u)"
  if [ "$(printf '%s\n' "$u" | grep -c .)" -eq 1 ]; then ok "all self-declared build versions agree ($u)"
  else note "build versions differ: $(echo $u) — legitimate when one engine bumped alone (a wire-key change arms §2.1); pass a version to assert the release set"; fi
fi
[ -n "$WANT_VER" ] && { printf '%s\n' "${builds[@]}" | grep -qxv "$WANT_VER" && bad "a build version != requested $WANT_VER" || ok "build versions == requested $WANT_VER"; }

echo
if [ "$fail" = 0 ]; then echo "release-preflight: OK${FLOOR:+ (floor $FLOOR)}"; else echo "release-preflight: $fail check(s) FAILED — resolve before publishing"; fi
exit "$fail"
