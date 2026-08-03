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
# ⟨0.24⟩ INCREMENT, do not assign. This was `fail=1`, so the summary below reported "1 check(s) FAILED"
# no matter how many fired — a preflight that under-counts its own findings is the same shape as an
# engine that under-reports, and it is worse here because the number is what tells you whether the last
# fix helped.
bad()  { echo "  ✘ $*"; fail=$((fail + 1)); }
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
# THE AUTHORITATIVE FLOOR IS SPEC.md's OWN DECLARATION, not engine agreement.
# It used to be derived from agreement, and a disagreement set FLOOR="" — which silently DISABLED check
# [2], the bump-miss detector. So the one check that exists to catch a half-finished bump was inert
# EXACTLY when a bump was half-finished, which is the only time it matters. Found during the 0.23→0.24
# bump: [2] printed "(no prior floor to check)" while NINE leftover strings sat in test pins, smoke
# assertions and shipped docs across four repos — every one found afterwards by a failing test instead.
EXTRA_FLOORS=""   # set only when the engines disagree; see the fallback below
SPEC_FLOOR="$(grep -oE '^\*\*Version [0-9]+\.[0-9]+' "$ROOT/candor-spec/SPEC.md" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
FLOOR=""
if [ "${#specs[@]}" -gt 0 ]; then
  UNIQ="$(printf '%s\n' "${specs[@]}" | sort -u)"
  if [ "$(printf '%s\n' "$UNIQ" | grep -c .)" -eq 1 ]; then ok "all declare spec $UNIQ"; FLOOR="$UNIQ"
  else bad "engines DISAGREE on the declared spec: $(echo $UNIQ)"; fi
fi
# Fall back to the declared floor so [2] still runs. A disagreement is a finding in ITS OWN right; it must
# not also suppress a different check.
#
# BUT THE FALLBACK CAN BE WRONG, AND A WRONG GREEN TICK IS WORSE THAN THE INERT CHECK IT REPLACED. If the
# disagreement is SPEC.md ITSELF lagging (engines bumped first — the ordinary mid-bump state), SPEC_FLOOR is
# the STALE value, PRIOR computes one rung too low, and [2] reports "no leftover 'spec 0.22' strings" while
# every 0.23 stray is invisible. So when the engines disagree we scan the predecessor of EVERY distinct
# declared value, not just SPEC.md's — the union can only over-report, and over-reporting here is noise
# while under-reporting is a false all-clear.
if [ -z "$FLOOR" ] && [ -n "$SPEC_FLOOR" ]; then
  FLOOR="$SPEC_FLOOR"
  note "engines disagree; scanning the predecessor of EVERY declared value, not just SPEC.md's $SPEC_FLOOR"
  EXTRA_FLOORS="$(printf '%s\n' "${specs[@]}" | sort -u | tr '\n' ' ')"
fi
[ -n "$WANT_SPEC" ] && { [ "$FLOOR" = "$WANT_SPEC" ] && ok "floor == requested $WANT_SPEC" || bad "floor '$FLOOR' != requested '$WANT_SPEC'"; }

# --- 2. no LEFTOVER PRIOR-FLOOR spec string in shipped code / tests / CI scripts -------------------------
# The bug class: a bump moves the SPEC_VERSION constant but misses a `spec 0.9` baked into a CI-only script
# (smoke.sh / integration.sh) or a golden. The precise signature is a leftover string of the PRIOR floor
# (0.10 → 0.9) — distinct from intentionally-OLDER fixtures (a SARIF converter tested against a spec-0.7
# envelope) and CHANGELOG/design history, which are NOT flagged. Excludes vendor/build dirs, CHANGELOG,
# narrative docs, ⟨X⟩ era markers.
prior_of() { # $1 = X.Y  ->  X.(Y-1), or empty at a major boundary
  local mj="${1%%.*}" mn="${1#*.}"
  [ "$mn" -gt 0 ] 2>/dev/null && printf '%s.%s' "$mj" "$((mn-1))"
}
PRIOR="$(prior_of "$FLOOR")"
# When the engines disagreed we do NOT trust one value's predecessor: scan the predecessor of EVERY
# distinct declared value. The union can only OVER-report, and over-reporting here is noise while
# under-reporting is a false all-clear about the wrong version entirely.
PRIORS="$PRIOR"
for v in $EXTRA_FLOORS; do
  pv="$(prior_of "$v")"
  case " $PRIORS " in *" $pv "*) ;; *) [ -n "$pv" ] && PRIORS="$PRIORS $pv";; esac
done
PRIORS="$(printf '%s' "$PRIORS" | tr -s ' ')"

# WHICH LEFTOVERS ARE LOUD. Defined HERE, not inside [2]'s else-branch: it used to be, and when [2] found
# nothing while [2b] found something the variable was unset, `set -u` aborted the command substitutions
# (`|| true` cannot rescue an expansion error), `litloud` came back empty and the script took the SUCCESS
# branch — a GREEN TICK OVER A STALE ASSERTION IT HAD ACTUALLY FOUND, in exactly the common case of a bump
# that missed only a bare-literal assertion.
#
# And the classification is now by CONTENT, not by PATH. The path form was an ALLOWLIST of places assumed
# safe ("under tests/ ⇒ a deliberate input fixture"), and it had the premise backwards: an assertion pinning
# the engine's EMITTED spec lives under tests/ BY CONSTRUCTION. Measured over the family — 14 output
# assertions at the current floor, of which the path form would have called **12 advisory**. So an
# ASSERTION is loud wherever it lives; only a line that CONSTRUCTS a document is advisory. That is a
# denylist over the advisory bucket, which is the direction this family's own rule requires.
ASSERTION_RE='(want|assert|assert_eq|expect|check|XCTAssert|toBe|toEqual|deepEqual|should)'
FIXTURE_PATH_RE='(^|/)(tests?|fixtures?|conformance)/|/tests?[.]|test[-_.][a-z]*[.](mjs|py|sh|rs|js)|src/tests[.]rs|[.]test[.]'
# Two content rules that override the assertion verb, because the verb list is made of ENGLISH WORDS and
# fires on prose. Both were found by running this against a clean tree and reading the 15 false positives:
#   COMMENT_RE  — `check`/`expect`/`should` in a doc comment EXPLAINING the defect. Scoped to fixture paths
#                 so a comment in SHIPPED source (an agent-facing doc claim) stays loud.
#   CONSTRUCT_RE — a line that BUILDS a report document rather than asserting on one. A shipped constant
#                 or a doc line can never appear inside `r#"{"candor"` / `{"candor":{`.
COMMENT_RE='^[^:]*:[0-9]+:[ \t]*(//|#|/[*]|[*]|--)'
CONSTRUCT_RE='r#"[{] *"candor"|[{]"candor" *:|JSON[.]stringify[(][{]'
# ADVISORY := (fixture-path AND not-an-assertion) OR (fixture-path AND a comment) OR document-construction.
# One pass, one predicate. The previous form piped stdin into TWO greps inside a brace group — the first
# consumed the whole stream and the second saw nothing, so the comment and construction rules never fired.
#   ADVISORY := (fixture-path OR constructs-a-document)
#               AND NOT (asserts AND is-not-a-comment AND is-not-a-construction)
advisory_filter() {
  awk -v fx="$FIXTURE_PATH_RE" -v as="$ASSERTION_RE" -v cm="$COMMENT_RE" -v ct="$CONSTRUCT_RE" '
    { l = tolower($0)
      isfx = (l ~ tolower(fx)); isct = ($0 ~ ct); isas = (l ~ tolower(as)); iscm = ($0 ~ cm)
      if ((isfx || isct) && !(isas && !iscm && !isct)) print }'
}
# NOTE both filters are applied to the whole `path:lineno:content` line, so a doc that merely MENTIONS a
# test path is masked. Accepted knowingly: the alternative is splitting on the second colon, which breaks
# on Windows-style paths. The assertion rule above is what carries the weight.
echo "[2] no leftover prior-floor (${PRIORS:-?}) spec strings — the bump-miss signature"
for PRIOR in $PRIORS; do
  strays="$(cd "$ROOT" && grep -rInE "spec[ :\"]+${PRIOR//./\\.}([^0-9]|$)" \
      --exclude-dir=target --exclude-dir=node_modules --exclude-dir=.build --exclude-dir=build \
      --exclude-dir=.git --exclude-dir=eval --exclude-dir=.gradle --exclude-dir=docs --exclude-dir=.candor \
      --exclude='CHANGELOG*' --exclude=BACKLOG.md --exclude='*DESIGN*.md' --exclude='*-LOG.md' \
      --exclude='*WORK-QUEUE.md' \
      --exclude=release-preflight.sh --exclude=scan.py --exclude=Candor.java --exclude=main.swift \
      candor-spec candor-rust candor-ts candor-java candor-swift candor-agents candor 2>/dev/null \
    | grep -vE '⟨(spec )?[0-9]' | grep -v ', informative)' )"
  if [ -z "$strays" ]; then ok "no leftover 'spec $PRIOR' strings"
  else
    # A leftover in a FIXTURE is usually deliberate (a 0.24 engine reading a 0.23 report is real
    # backward-compat coverage); a leftover in a doc, a packaging file or shipped source is a defect.
    # Both are shown — only the second fails the run, because 220 advisory lines burying 15 real ones is
    # how the 0.23→0.24 bump shipped with its leftovers in the first place.
    loud="$(printf '%s\n' "$strays"    | grep -vEi "$FIXTURE_PATH_RE" || printf '%s\n' "$strays" | grep -Ei "$ASSERTION_RE" || true)"
    _adv="$(printf '%s\n' "$strays" | { advisory_filter || true; })"
    loud="$(printf '%s\n' "$strays" | grep -v '^$' | sort -u | comm -23 - <(printf '%s\n' "$_adv" | grep -v '^$' | sort -u) || true)"
    quiet_n="$(printf '%s\n' "$_adv" | grep -c . || true)"
    if [ -n "$loud" ]; then
      bad "leftover 'spec $PRIOR' in shipped source/docs/packaging (a bump missed these):"; printf '%s\n' "$loud" | sed 's/^/      /'
    else
      ok "no leftover 'spec $PRIOR' outside tests/fixtures"
    fi
    [ "$quiet_n" -gt 0 ] && note "($quiet_n more in tests/fixtures/conformance — usually DELIBERATE backward-compat inputs; run with SHOW_FIXTURES=1 to list)"
    [ "${SHOW_FIXTURES:-}" = "1" ] && printf '%s\n' "$strays" | grep -Ei "$FIXTURE_RE" | sed 's/^/      /'
  fi

  # [2b] BARE-LITERAL spec assertions the [2] grep misses: a `]`/`,`/`==`/`as? String` between "spec" and the
  # quoted prior-floor breaks the `spec[ :"]+0.X` pattern — e.g. rust `assert_eq!(v["spec"], "0.16")`, swift
  # `XCTAssertEqual(obj?["spec"] as? String, "0.16")`. These dodge preflight AND `cargo/npm/swift test`'s
  # OWN default (they only fire the differential in CI / a `swift test` run). Signature: a line carrying BOTH
  # `spec` and the bare quoted prior-floor `"0.X"`. A legit older fixture (spec "0.7") won't match the floor.
  litstrays="$(cd "$ROOT" && grep -rIn "\"${PRIOR//./\\.}\"" \
      --exclude-dir=target --exclude-dir=node_modules --exclude-dir=.build --exclude-dir=build \
      --exclude-dir=.git --exclude-dir=.gradle --exclude-dir=docs --exclude-dir=.candor \
      --exclude='CHANGELOG*' --exclude=BACKLOG.md --exclude='*DESIGN*.md' --exclude='*-LOG.md' \
      --exclude='*WORK-QUEUE.md' \
      --exclude=release-preflight.sh --exclude=scan.py --exclude=Candor.java --exclude=main.swift \
      candor-spec candor-rust candor-ts candor-java candor-swift candor-agents candor 2>/dev/null \
    | grep -iw spec | grep -vE '⟨(spec )?[0-9]' | grep -v ', informative)' )"
  if [ -z "$litstrays" ]; then ok "no bare-literal 'spec' == \"$PRIOR\" assertions"
  else
    # Same loud/advisory split as [2] — [2b] was the half that still dumped every fixture, which is the
    # asymmetry the review caught: the exclusion went into [2] and not here, so the noise survived.
    _adv="$(printf '%s\n' "$litstrays" | { advisory_filter || true; })"
    litloud="$(printf '%s\n' "$litstrays" | grep -v '^$' | sort -u | comm -23 - <(printf '%s\n' "$_adv" | grep -v '^$' | sort -u) || true)"
    litquiet="$(printf '%s\n' "$_adv" | grep -c . || true)"
    if [ -n "$litloud" ]; then
      bad "bare-literal spec assertion at the prior floor in shipped source/docs (only \`*test\` catches these):"; printf '%s\n' "$litloud" | sed 's/^/      /'
    else
      ok "no bare-literal 'spec' == \"$PRIOR\" assertions outside tests/fixtures"
    fi
    [ "$litquiet" -gt 0 ] && note "($litquiet more in tests/fixtures/conformance — usually deliberate inputs; SHOW_FIXTURES=1 to list)"
    [ "${SHOW_FIXTURES:-}" = "1" ] && printf '%s\n' "$litstrays" | grep -Ei "$FIXTURE_RE" | sed 's/^/      /'
  fi
done
[ -z "$PRIORS" ] && note "(no prior floor to check)"

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

# --- 5. every CHANGELOG mentions the floor being cut -----------------------------------------------------
# Checks 2 and 3 EXCLUDE CHANGELOG from the stale-string sweep, and rightly so: a changelog is a history, so
# old rung text in it is correct rather than stale. But excluding it from the negative check left no positive
# one — and on 2026-08-01 the umbrella's CHANGELOG was found sitting at spec 0.18, three rungs behind the
# release it was shipping, while ENGINE_PIN had moved beneath it several times. Nothing had ever asked the
# one question that matters: does the file describing this release mention this release?
echo "[5] every CHANGELOG mentions the floor being cut"
if [ -n "$FLOOR" ]; then
  for r in candor-spec candor-rust candor-java candor-ts candor-swift candor candor-agents; do
    f="$ROOT/$r/CHANGELOG.md"
    [ -f "$f" ] || { note "$r: no CHANGELOG.md — skipped"; continue; }
    if grep -qE "(^|[^0-9.])${FLOOR//./\\.}([^0-9]|$)" "$f"; then ok "$r mentions $FLOOR"
    else bad "$r CHANGELOG.md has no $FLOOR entry — the release notes do not describe the release"; fi
  done
else
  note "no floor derived — skipped"
fi

# ── [6] INTER-CRATE DEPENDENCY VERSIONS ────────────────────────────────────────────────────────────
# A rust crate that depends on a SIBLING at the prior floor does not just fail a test — `cargo publish`
# resolves that requirement from crates.io, so the sequence dies PART-WAY with the earlier crates already
# uploaded and unyankable. On the 0.25 bump the workspace ROOT still required `^0.24.0` from two of its own
# crates; `cargo test` caught it locally, but only because a human ran the tests before the publish. This
# makes it a preflight failure, where the cost is a message instead of a half-published floor.
echo "[6] no crate requires a sibling at a prior version"
if [ -n "$WANT_VER" ]; then
  bad_dep=0
  while IFS= read -r f; do
    while IFS= read -r line; do
      dv="$(printf '%s' "$line" | grep -oE 'version = "\^?[0-9]+\.[0-9]+\.[0-9]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      [ -n "$dv" ] || continue
      [ "$dv" = "$WANT_VER" ] && continue
      bad "$(basename "$(dirname "$f")")/$(basename "$f"): requires a candor sibling at $dv, not $WANT_VER — cargo publish resolves this from crates.io and dies MID-SEQUENCE"
      bad_dep=$((bad_dep + 1))
    done < <(grep -E '^candor-(report|classify|scan|query) *=.*version' "$f" 2>/dev/null)
  done < <(find "$ROOT/candor-rust" -name Cargo.toml -not -path '*/target/*' 2>/dev/null)
  [ "$bad_dep" = 0 ] && ok "every candor→candor dependency requires $WANT_VER"
fi

# ── [7] JAVA'S GRADLE VERSION ──────────────────────────────────────────────────────────────────────
# This used to be skipped with the note "java engine: generated at build time (git hash) — not a
# hand-maintained constant". The `--version` STRING is generated; `build.gradle.kts`'s `version` is NOT,
# and it names the jar. `release.sh` does `ls candor-java-$WANT_VER-all.jar || die`, so a missed bump here stops
# the release at step 3 — after crates.io and the npm tag have already gone out irreversibly. A documented
# blind spot is still a blind spot.
echo "[7] candor-java's gradle version names the jar the release will look for"
JGRADLE="$(grep -oE '^version = "[0-9]+\.[0-9]+\.[0-9]+"' "$ROOT/candor-java/build.gradle.kts" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [ -z "$JGRADLE" ]; then bad "candor-java/build.gradle.kts: no top-level version found"
elif [ -n "$WANT_VER" ] && [ "$JGRADLE" != "$WANT_VER" ]; then
  bad "candor-java gradle version is $JGRADLE, not $WANT_VER — release.sh needs candor-java-$WANT_VER-all.jar and dies without it"
else ok "gradle version $JGRADLE"; fi

# ── [8] THE PUBLISHER AND THE VERIFIER MUST AGREE ON WHAT A RELEASE IS ─────────────────────────────
# `release.sh` cut FOUR GitHub releases while `release-verify.sh` checked SEVEN, so three repos were
# tagged and never released and the verifier failed on repos the publisher was never asked to cut. Neither
# script is wrong on its own terms — only the PAIR is, which is why no test inside either could see it.
# Comparing them is the whole check.
echo "[8] release.sh and release-verify.sh name the same repos"
PUB="$(grep -oE '^rel candor[a-z-]*' "$ROOT/candor/bin/release.sh" 2>/dev/null | awk '{print $2}' | sort -u)"
VFY="$(grep -oE '"candor[a-z-]*:v\$(VER|SPEC)"' "$ROOT/candor/bin/release-verify.sh" 2>/dev/null | sed 's/"//g; s/:v\$.*//' | sort -u)"
if [ -z "$PUB" ] || [ -z "$VFY" ]; then bad "could not read a repo list from one of the scripts — this check would pass over nothing"
elif [ "$PUB" = "$VFY" ]; then ok "both name $(printf '%s' "$PUB" | grep -c .) repos"
else
  bad "publisher and verifier disagree — cut only: $(comm -23 <(printf '%s\n' "$PUB") <(printf '%s\n' "$VFY") | tr '\n' ' ')| checked only: $(comm -13 <(printf '%s\n' "$PUB") <(printf '%s\n' "$VFY") | tr '\n' ' ')"
fi

# ── [9] NOTHING MAY STILL BE SITTING UNDER `## Unreleased` WHEN A VERSION IS CUT ───────────────────
# Cutting 0.25 left FOUR engine CHANGELOGs with a non-empty `## Unreleased` section — and the v0.25.0 tag
# contains the commits that wrote it, so that work SHIPPED while still labelled unreleased. Anyone reading
# those files afterwards would take shipped work for pending work.
#
# The check is deliberately here and not in `release.sh`: that script's contract is that the version is
# ALREADY bumped, committed and pushed (it refuses to run on a dirty tree), so having it rewrite and
# re-commit a CHANGELOG mid-publish would contradict its own gate. Preflight is where "is this staged
# correctly" lives, and a gate that names the fix beats a script that silently performs it.
#
# Only a BARE `## Unreleased` / `## [Unreleased]` counts — optionally carrying a version tag, which is the
# shape the family actually writes (`## Unreleased — ⟨spec 0.26⟩`). A QUALIFIED one is a deliberately
# separate section and must not be flagged: candor-rust keeps `## [Unreleased] (nightly lint)` for a
# component with its own cadence. EMPTY is fine too — an empty placeholder at the top is the convention,
# and only CONTENT would ship unlabelled.
# ONLY WHEN A VERSION IS BEING ASSERTED. Preflight is also run as a plain health check
# (`release-preflight.sh 0.26`, no version), and in THAT mode content under `## Unreleased` is the normal
# staging state — the whole point of the section. Flagging it there would turn everyday use red and teach
# the reader to ignore the tool, which is how a gate stops being one.
echo "[9] no non-empty \`## Unreleased\` section left when cutting${WANT_VER:+ $WANT_VER}"
if [ -z "$WANT_VER" ]; then
  note "— skipped: no version argument. Content under \`## Unreleased\` is the normal staged state; pass a version to check it"
fi
u_any=0
for r in candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor; do
  [ -n "$WANT_VER" ] || continue
  f="$ROOT/$r/CHANGELOG.md"
  [ -f "$f" ] || continue
  # the line number of a BARE Unreleased heading, and of the next `## ` heading after it
  ln="$(grep -nE '^## \[?Unreleased\]?[[:space:]]*(—.*)?$' "$f" | head -1 | cut -d: -f1)"
  [ -n "$ln" ] || continue
  nxt="$(awk -v s="$ln" 'NR>s && /^## /{print NR; exit}' "$f")"
  [ -n "$nxt" ] || nxt="$(wc -l < "$f")"
  body="$(awk -v a="$ln" -v b="$nxt" 'NR>a && NR<b' "$f" | grep -cE '[^[:space:]]')"
  if [ "${body:-0}" -gt 0 ]; then
    u_any=1
    bad "$r: \`## Unreleased\` (line $ln) has $body non-blank line(s) — rename it to the version being cut (e.g. \`## [$WANT_VER] — $(date +%F)\`) and open a fresh empty one, or its contents ship unlabelled"
  fi
done
[ "$u_any" = 0 ] && [ -n "$WANT_VER" ] && ok "no CHANGELOG has content stranded under \`## Unreleased\`"

echo
if [ "$fail" = 0 ]; then
  echo "release-preflight: OK${FLOOR:+ (floor $FLOOR)}"
else
  echo "release-preflight: $fail check(s) FAILED — resolve before publishing"
fi
# NOT `exit "$fail"`. Now that it counts, exiting the count would make 256 failures exit 0 — a wrap to
# green, on the one script whose entire job is to stand between a defect and a publish.
[ "$fail" = 0 ] || exit 1
exit 0
