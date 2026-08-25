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
# CANDOR_ROOT lets the test harness point these at a FIXTURE tree instead of the real siblings.
# Without it neither script can be exercised without editing six live repos, which is why nine
# defects across 0.25 and 0.26 were found by publishing rather than by testing.
ROOT="${CANDOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"   # the dir holding candor-* siblings
# ⟨0.29⟩ THE CONFORMANCE EVIDENCE PATH IS DERIVED FROM $ROOT, not a fixed global. `release-test.sh` runs
# THIS script against a sandbox tree whose `conformance/run.sh` is a stub printing `conformance: OK (stub)`
# — and with a fixed `/tmp/rel-conformance.txt` that stub's output landed on the REAL evidence file. Found
# by a release panel that went looking for the green run behind item [11] and found a 36-byte stub sitting
# where the proof should be. A test overwriting the artifact production cites is the evidence-contamination
# class this project already has a rule about; deriving the name from the root keeps a sandbox in its lane.
CONF_LOG="${TMPDIR:-/tmp}/rel-conformance-$(printf '%s' "$ROOT" | cksum | cut -d' ' -f1).txt"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"                        # this script's own bin/
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
info() { echo "  • $*"; }   # a pass that is worth explaining rather than just ticking

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
if [ -z "$FLOOR" ] && [ -n "${SPEC_FLOOR}" ]; then
  FLOOR="${SPEC_FLOOR}"
  note "engines disagree; scanning the predecessor of EVERY declared value, not just SPEC.md's ${SPEC_FLOOR}"
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
# The SUFFIX form was missing: this matched `test-foo.sh` but not `foo-test.sh`, so `bin/release-test.sh`
# — a file whose entire job is to BUILD a fixture changelog at the prior version — was reported as a
# shipped-source bump-miss on every cut. A fixture flagged as a defect trains the reader to skim the list
# that exists to be read.
FIXTURE_PATH_RE='(^|/)(tests?|fixtures?|conformance)/|/tests?[.]|test[-_.][a-z]*[.](mjs|py|sh|rs|js)|[-_.]test[.](mjs|py|sh|rs|js)|src/tests[.]rs|[.]test[.]'
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
  # The separator class was `[ :"]+`, which misses the LINKED form a README naturally writes:
  # `[candor-spec](https://…/candor-spec) 0.25` puts a `)` between the word and the version. That is
  # exactly how a stale string survived the 0.26 bump on candor-swift's README and reached CI, where its
  # own drift gate caught what this check had passed. `[^0-9]{0,4}` covers `spec 0.25`, `spec: "0.25`,
  # `spec) 0.25` and `spec — 0.25` without reaching across a sentence.
  strays="$(cd "$ROOT" && grep -rInE "spec[^0-9]{0,4}${PRIOR//./\\.}([^0-9]|$)" \
      --exclude-dir=target --exclude-dir=node_modules --exclude-dir=.build --exclude-dir=build \
      --exclude-dir=.git --exclude-dir=eval --exclude-dir=.gradle --exclude-dir=docs --exclude-dir=.candor \
      --exclude='CHANGELOG*' --exclude=BACKLOG.md --exclude='*DESIGN*.md' --exclude='*-LOG.md' \
      --exclude='*WORK-QUEUE.md' \
      --exclude='NIGHT-*.md' \
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
      --exclude='NIGHT-*.md' \
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
    # PRE-PUBLISH THIS IS EXPECTED, AND UNTIL NOW IT DEADLOCKED THE RELEASE. [3]'s own message says the
    # pins move AFTER the release exists — while `release.sh` step 0 refuses to publish unless preflight
    # is fully green. So the strict form could never be satisfied at the moment release.sh runs, and every
    # release had to bypass the script that exists because bypassing it lost three steps on 0.24.
    #
    # The other design — moving pins WITH the engines — was tried on 0.24 and shipped `jbang-catalog.json`
    # pinned at a release that did not exist, which is why `release-verify.sh` now RESOLVES the artifact
    # instead of matching the string. So pins-after is the right order; this just stops it deadlocking.
    if [ -n "${PINS_ADVISORY:-}" ]; then
      info "$1: pin still at the previous version — expected pre-publish, must be updated after"
    else
      bad "$1: pin does not reference $WANT_VER (update AFTER the release is published)"
    fi
  fi
}
checkpin "adopt java  " "candor/adopt/candor.yml"        'CANDOR_JAVA_VERSION:[[:space:]]*[0-9]'
checkpin "adopt agents" "candor/adopt/candor-digest.yml" 'candor-agents@'
checkpin "jbang       " "candor-java/jbang-catalog.json" 'releases/download'
# The umbrella's ENGINE_PIN is what `candor update` fetches — a SEPARATE constant from UMBRELLA_VERSION.
# It lagged at 0.18.0 through the 0.23.1 ship (brew updated the umbrella, engines stayed 0.18) → gate it:
# on an engine release it MUST equal the release version. (Umbrella-only CLI patches don't run this arg.)
checkpin "engine pin  " "candor/bin/candor"              'ENGINE_PIN='
# ⟨0.29⟩ THE TWO IDE INTEGRATIONS PIN THE ENGINE THEY BUNDLE, and neither was ever registered here.
# `candorTsVersion` is not documentation: it is the version `stage-server.mjs` installs from npm and
# esbuild bundles into the shipped extension (JetBrains does the same in gradle), so a stale pin ships a
# stale ENGINE to every IDE user. MEASURED 2026-08-16: both sat at 0.16.0 while candor-ts was 0.28.2 —
# twelve rungs, including the ⟨0.29⟩ fix for `forbid` being ANSWERED FROM A REPORT on the LSP channel,
# which is a defect these two are the delivery vehicle for. Nothing failed, because nothing asked.
checkpin "vscode ts   " "candor/integrations/vscode/package.json"     '"candorTsVersion"'
checkpin "jetbrains ts" "candor/integrations/jetbrains/gradle.properties" 'candorTsVersion='
# ⟨0.29⟩ …AND THE JVM ENGINE THE SAME PLUGIN EMBEDS. The commit that registered the TS pins fixed one of
# the two pins in THIS FILE and left its sibling on the line above at 0.16.0 — a sibling-route miss inside
# the fix for a sibling-route problem, found by review. The plugin downloads and ships this jar for its
# post-build hook, so a stale pin here runs a twelve-rung-old ENGINE against the user's build.
checkpin "jetbrains jvm" "candor/integrations/jetbrains/gradle.properties" 'candorJavaVersion='

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
grabver "umbrella      " "candor/bin/candor"                             'UMBRELLA_VERSION="[0-9.]+'
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

# --- 5b. and does it describe the WHOLE release, or only the part that was done when it was cut? ---------
# Check [5] is a NECESSARY condition that a stale section passes trivially. `release-stage.sh` renames
# `## Unreleased` to `## [X.Y.Z] — <date>` at STAGING time, so the section carries the floor string from the
# moment it is cut. Work then continues and lands inside it, which is right — but the NARRATIVE was written
# for the tree as it stood that morning. Measured 2026-08-05: the 0.27 sections described "resolves + fs
# kinds" while the release had since grown thirty privacy keys, `--target`, `--xml`, a new §2 field and three
# rounds of review fixes. [5] was green throughout. The invariant [5] cannot see is RECENCY — did the
# description stop moving while the thing it describes kept going?
#
# This runs in EVERY mode, not release-only. A changelog that has fallen behind is a fact about the tree
# today, and the release is exactly when it is most expensive to discover.
echo "[5b] no CHANGELOG lags its own source"
if [ -x "$HERE/changelog-lag.sh" ]; then
  if out="$(CANDOR_ROOT="$ROOT" "$HERE/changelog-lag.sh" 2>&1)"; then
    ok "every changelog is at least as new as its source"
  else
    printf '%s\n' "$out" | sed 's/^/  /'
    bad "a changelog describes less than its repo ships — see the commits above"
  fi
else
  bad "bin/changelog-lag.sh is missing or not executable — [5] alone cannot see a STALE section"
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
# …AND THE JAR MUST ACTUALLY EXIST. The check above compares a version STRING; `release.sh` step 3 then
# needs the FILE, and it is the third step — after crates.io (unyankable) and the npm tag. A never-built
# jar therefore kills the publish PART-WAY, with the earlier artifacts already out. That is the same
# distinction release-verify.sh's own header is about: a pin naming a URL is not the URL existing, and a
# version naming a jar is not the jar existing.
if [ -n "$WANT_VER" ]; then
  JJAR="$ROOT/candor-java/build/libs/candor-java-$WANT_VER-all.jar"
  if [ -f "$JJAR" ]; then ok "the jar release.sh will upload exists ($(du -h "$JJAR" | cut -f1))"
  else bad "candor-java-$WANT_VER-all.jar is NOT built — release.sh needs it at step 3, AFTER crates.io (unyankable) and the npm tag; build it first: (cd candor-java && ./gradlew shadowJar)"; fi
fi

# ── [8] THE PUBLISHER AND THE VERIFIER MUST AGREE ON WHAT A RELEASE IS ─────────────────────────────
# `release.sh` cut FOUR GitHub releases while `release-verify.sh` checked SEVEN, so three repos were
# tagged and never released and the verifier failed on repos the publisher was never asked to cut. Neither
# script is wrong on its own terms — only the PAIR is, which is why no test inside either could see it.
# Comparing them is the whole check.
# The repo list for [7b]/[7c], derived from release.sh itself — the same derivation [8] uses — so it can
# never become a hand-kept allowlist whose omissions are silent.
WFREPOS="$(grep -oE '^rel candor[a-z-]*' "$ROOT/candor/bin/release.sh" 2>/dev/null | awk '{print $2}' | sort -u)"
[ -n "$WFREPOS" ] || WFREPOS="candor-spec candor-rust candor-ts candor-java candor-swift candor-agents candor"
echo "[7c] no commit message shows shell-substitution damage"
# WHAT IT MATCHES, and what it deliberately does NOT. Spliced BUILD OR TEST OUTPUT is the signature —
# `test result: ok. 38 passed`, a `Compiling foo v0.1.0` line, an `Executed 794 tests` line — because
# nobody writes those inside a sentence on purpose. The first version also matched "command not found",
# which flagged candor-java@626e1f4: a commit whose message CORRECTLY DESCRIBES an earlier corruption.
# A detector that fires on writing about the defect is worse than none, so that pattern is gone.
#
# A message written as `git commit -m "…`cmd`…"` has its backticks EXECUTED by the shell before git sees
# it, so the commit ships with command output spliced in and the intended words gone. It happened FOUR
# times on 2026-08-19 — one message shipped `test result: ok. 38 passed;` in the middle of a sentence,
# another lost the word it was quoting entirely. git cannot refuse this (the damage precedes it), and the
# message is permanent once pushed, so the only place to catch it is a scan of what was actually written.
# The fix is to write messages via `git commit -F -` with a QUOTED heredoc, which no shell expands.
DAMAGED=""
for r in $WFREPOS; do
  [ -d "$ROOT/$r" ] || continue
  base="$(git -C "$ROOT/$r" describe --tags --abbrev=0 2>/dev/null || echo HEAD~20)"
  # PER COMMIT, not per line: a body is multi-line, so grepping the whole log stream reports the matched
  # TEXT rather than the commit it came from — which is what the first version of this check printed.
  for h in $(git -C "$ROOT/$r" log --format='%h' "$base"..HEAD 2>/dev/null); do
    if git -C "$ROOT/$r" log -1 --format='%B' "$h" 2>/dev/null \
       | grep -qE "test result: (ok|FAILED)\. [0-9]+ passed|^ *Compiling [a-z-]+ v[0-9]|^ *Finished .(dev|release|test) profile|^ *Executed [0-9]+ tests, with"; then
      DAMAGED="$DAMAGED $r@$h"
    fi
  done
done
if [ -n "$DAMAGED" ]; then
  bad "commit message(s) carrying shell output — backticks were executed before git saw them:$DAMAGED"
else
  ok "no commit in the release range shows substitution damage"
fi

echo "[7b] every CI workflow declares a timeout"
# A workflow with no `timeout-minutes` inherits GitHub's SIX-HOUR default. On 2026-08-19 two hung for
# 3h45m with no log output and were given a deadline — and their four siblings were not, so `ci.yml`
# then hung for 54 minutes against an ~11-minute median, stalling this very gate ([10] reads CI green on
# HEAD) while looking indistinguishable from a slow job. Fixing the workflows that failed and not the
# ones beside them is the habit this family keeps finding in its own engines; this makes the omission
# impossible to leave behind, because it asks EVERY file in EVERY repo rather than the ones that broke.
MISSING=""
for r in $WFREPOS; do
  for wf in "$ROOT/$r"/.github/workflows/*.yml; do
    [ -e "$wf" ] || continue
    grep -q "timeout-minutes" "$wf" || MISSING="$MISSING $r/$(basename "$wf")"
  done
done
if [ -n "$MISSING" ]; then
  bad "workflow(s) with no \`timeout-minutes\` — a hang there blocks a release for up to 6 hours and reads as slow:$MISSING"
else
  ok "every workflow in every released repo declares a timeout"
fi

echo "[8] release.sh and release-verify.sh name the same repos"
PUB="$(grep -oE '^rel candor[a-z-]*' "$ROOT/candor/bin/release.sh" 2>/dev/null | awk '{print $2}' | sort -u)"
VFY="$(grep -oE '"candor[a-z-]*:v\$(VER|SPEC)"' "$ROOT/candor/bin/release-verify.sh" 2>/dev/null | sed 's/"//g; s/:v\$.*//' | sort -u)"
if [ -z "$PUB" ] || [ -z "$VFY" ]; then bad "could not read a repo list from one of the scripts — this check would pass over nothing"
elif [ "$PUB" = "$VFY" ]; then ok "both name $(printf '%s' "$PUB" | grep -c .) repos"
else
  bad "publisher and verifier disagree — cut only: $(comm -23 <(printf '%s\n' "$PUB") <(printf '%s\n' "$VFY") | tr '\n' ' ')| checked only: $(comm -13 <(printf '%s\n' "$PUB") <(printf '%s\n' "$VFY") | tr '\n' ' ')"
fi
# …and [5b]'s repo list must be the SAME list. changelog-lag.sh carries its own hard-coded REPOS line —
# an ALLOWLIST, in a script whose own header argues against allowlists because their omissions are
# silent. An eighth family repo would simply never be checked, and [5b] would go on printing OK. This
# ties it to the publisher's list, so adding a repo to the release without adding it there fails here.
LAG="$(sed -n 's/^REPOS="${1:-\(.*\)}"$/\1/p' "$HERE/changelog-lag.sh" 2>/dev/null | tr ' ' '\n' | grep -c . )"
LAGSET="$(sed -n 's/^REPOS="${1:-\(.*\)}"$/\1/p' "$HERE/changelog-lag.sh" 2>/dev/null | tr ' ' '\n' | grep . | sort -u)"
if [ -z "$LAGSET" ]; then bad "could not read changelog-lag.sh's REPOS list — [5b] may be checking nothing"
elif [ "$LAGSET" = "$PUB" ]; then ok "changelog-lag [5b] covers the same $LAG repos the release cuts"
else bad "changelog-lag [5b] checks a DIFFERENT set than release.sh cuts — unchecked: $(comm -23 <(printf '%s\n' "$PUB") <(printf '%s\n' "$LAGSET") | tr '\n' ' ')"
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

# ── [10] EVERY REPO'S CI MUST BE GREEN ON THE COMMIT BEING RELEASED ────────────────────────────────
# Nothing in the release path looked at CI. You could publish a commit whose own build was red — and that
# is not hypothetical: on 2026-08-03 candor-rust and candor-swift both went red on pushed HEADs, and the
# rust failure had SILENTLY DISABLED a liveness test (a stranded `#[test]`), so the tarball would have
# shipped a suite that passed by not running. Local `cargo test` cannot see that; CI did.
#
# Release mode only (a version argument), and SKIPPED — never failed — when `gh` is unavailable or
# unauthenticated, because preflight must stay usable offline. A skip says so loudly rather than passing
# quietly, since "could not check" and "checked and fine" are the two things this file exists to separate.
echo "[10] CI is green on each repo's HEAD${WANT_VER:+ (releasing $WANT_VER)}"
if [ -z "$WANT_VER" ]; then
  note "— skipped: no version argument; CI state matters at RELEASE time"
elif ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  note "— SKIPPED: no authenticated \`gh\`. This check did NOT run; verify CI by hand before publishing."
else
  ci_bad=0
  CI_WAIT_BUDGET="${CI_WAIT_BUDGET:-1200}"   # ONE budget for the whole check, not one per repo
  CI_WAIT_LEFT="$CI_WAIT_BUDGET"
  waited_any=0
  for r in candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor; do
    [ -d "$ROOT/$r/.git" ] || continue
    head_sha="$(git -C "$ROOT/$r" rev-parse HEAD 2>/dev/null)"
    verdicts="$(cd "$ROOT/$r" && gh run list --limit 15 --json headSha,conclusion,status,workflowName 2>/dev/null \
      | python3 -c "
import json,sys
h='$head_sha'
try: runs=json.load(sys.stdin)
except Exception: print('ERR'); raise SystemExit
mine=[x for x in runs if x['headSha']==h]
if not mine: print('NONE'); raise SystemExit
bad=[x for x in mine if (x['conclusion'] or x['status']) not in ('success','skipped')]
print('BAD ' + ', '.join('%s:%s'%(x['workflowName'],x['conclusion'] or x['status']) for x in bad) if bad else 'OK')
" 2>/dev/null)"
    # IN-PROGRESS IS NOT A FAILURE, IT IS A NOT-YET. `release.sh` steps 2–3 push the release TAGS, which
    # start candor-ts's OIDC `publish` and candor-swift's `release` — so the very next invocation of this
    # script, which is the one that resumes at step 7, is GUARANTEED to see its own workflows running and
    # fail. Measured on 0.28.1: a whole cycle spent re-running the release for that.
    #
    # WAITING, not ignoring. Those runs are the npm publish and the swift release build: cutting the
    # umbrella before they finish would point the front door at artifacts that may not exist, which is
    # the same class of defect the ENGINE_PIN guard at step 7 exists to prevent. So the fix is to wait
    # for the answer, never to stop asking the question. Bounded, and CI_NO_WAIT skips waiting for the
    # everyday standalone check where a 20-minute block would be wrong.
    # A4 — the budget is SHARED ACROSS REPOS, not per repo. `waited=0` sat inside this 7-repo loop, so the
    # "bounded at 20 minutes" the comment and CHANGELOG promised was really 7 × 20 = up to 140. One budget,
    # declared once before the loop (see CI_WAIT_LEFT above), spent by whichever repos need it.
    #
    # …and the message goes to fd 2, not stdout. release.sh runs this with `>/tmp/rel-preflight.txt 2>&1`,
    # so the one line explaining a multi-minute silence was written to a file nobody is watching. stderr is
    # redirected there too — but an operator running preflight directly (the documented `just preflight`)
    # now sees it, and that is the case where a silent terminal is alarming.
    while [ -z "${CI_NO_WAIT:-}" ] && [ "$CI_WAIT_LEFT" -gt 0 ] && \
          printf '%s' "$verdicts" | grep -qE "in_progress|queued|requested|waiting|pending"; do
      [ "$waited_any" = 0 ] && { waited_any=1; printf '  \033[33m•\033[0m %s\n' "$r: CI still running — waiting up to $((CI_WAIT_LEFT/60))m total (the release's own tag-triggered workflows)" >&2; }
      sleep 30; CI_WAIT_LEFT=$((CI_WAIT_LEFT-30))
      verdicts="$(cd "$ROOT/$r" && gh run list --limit 15 --json headSha,conclusion,status,workflowName 2>/dev/null \
        | python3 -c "
import json,sys
h='$head_sha'
try: runs=json.load(sys.stdin)
except Exception: print('ERR'); raise SystemExit
mine=[x for x in runs if x['headSha']==h]
if not mine: print('NONE'); raise SystemExit
bad=[x for x in mine if (x['conclusion'] or x['status']) not in ('success','skipped')]
print('BAD ' + ', '.join('%s:%s'%(x['workflowName'],x['conclusion'] or x['status']) for x in bad) if bad else 'OK')
" 2>/dev/null)"
    done
    # THE TIMEOUT IS JUDGED ON THE VERDICT, NOT THE CLOCK. This fired on the elapsed counter, so a repo
    # whose CI went green on the LAST poll was reported failed AND green in the same run — `bad` here plus
    # `✔ all 7 repos green` below, and release.sh died on a family that was entirely passing. Ask the
    # question the check is about: is it STILL unfinished?
    if printf '%s' "$verdicts" | grep -qE "in_progress|queued|requested|waiting|pending"; then
      # ci_bad=1, AND IT WAS THE POINT. The `continue` below skips the `case`, which is the only place
      # ci_bad was ever set — so this branch reported ✘ for a stuck repo and then the summary printed
      # "✔ all 7 repos green on HEAD" underneath it. That is the failed-AND-green contradiction the
      # comment directly above says this hunk removed, reintroduced from the other side by the fix for it.
      ci_bad=1
      # THE WHOLE VERDICT, not just the word "unfinished". `BAD build:failure, publish:in_progress`
      # matches the pending regex, so a repo with a REAL failure beside a running job was reported only
      # as "still waiting" and the failure string never reached the operator at all.
      waited_note="after the shared $((CI_WAIT_BUDGET/60))m wait budget"
      [ -n "${CI_NO_WAIT:-}" ] && waited_note="and CI_NO_WAIT meant this run never waited for it"
      bad "$r: CI still unfinished $waited_note — ${verdicts#BAD } — re-run when it settles"
      # …and skip the case statement below, which would count the same stuck repo a SECOND time via its
      # BAD* arm. The ⟨0.24⟩ note on this counter is explicit that the number is load-bearing: a preflight
      # that miscounts its own findings is the shape of an engine that under-reports.
      continue
    fi
    case "$verdicts" in
      OK)   ;;
      NONE)
        # NO RUN IS NOT THE SAME AS NO EVIDENCE. Every umbrella workflow is path-filtered, so a commit
        # touching only BACKLOG.md or a doc legitimately triggers nothing — and this check failed the
        # 0.26 release for exactly that, on a backlog edit. A gate that fails routinely on a benign
        # shape is a gate that gets waved through, which is worse than not having it.
        #
        # So: distinguish. If HEAD is not pushed, that is still fatal. If it is pushed and simply
        # matched no path filter, report it and pass — the last commit that DID run CI is the one the
        # release actually depends on, and it is checked below.
        if ! git -C "$ROOT/$r" merge-base --is-ancestor HEAD "@{u}" 2>/dev/null; then
          ci_bad=1; bad "$r: HEAD ($head_sha) is NOT PUSHED — nothing could have run"
        else
          last="$(cd "$ROOT/$r" && gh run list --limit 15 --json headSha,conclusion,status \
            | python3 -c "
import json,sys
runs=json.load(sys.stdin)
done=[x for x in runs if x['conclusion']]
print('%s %s' % (done[0]['headSha'][:7], done[0]['conclusion']) if done else 'none none')" 2>/dev/null)"
          set -- $last
          if [ "${2:-none}" = "success" ]; then
            info "$r: HEAD matched no workflow path filter (pushed, docs-only); last CI run $1 green"
          else
            ci_bad=1; bad "$r: HEAD triggered no workflow AND the last completed run ($1) was ${2:-unknown}"
          fi
        fi
        ;;
      ERR|"") ci_bad=1; bad "$r: could not read CI status — treat as NOT verified";;
      BAD*) ci_bad=1; bad "$r: ${verdicts#BAD }";;
    esac
  done
  [ "$ci_bad" = 0 ] && ok "all 7 repos green on HEAD"
fi

# ── [11] THE FOUR-WAY CONFORMANCE SUITE MUST PASS ──────────────────────────────────────────────────
# The floor is CONFORMANCE-PINNED (SPEC §2 versioning policy), so publishing a floor whose suite has not
# been run publishes an unbacked claim. The standing checklist said "run it"; nothing enforced it, and a
# checklist step that is not a gate is a step that gets skipped on a busy day. Release mode only — the
# suite takes minutes, which is right for a publish and wrong for an everyday health check.
echo "[11] four-way conformance suite${WANT_VER:+ (releasing $WANT_VER)}"
if [ -z "$WANT_VER" ]; then
  note "— skipped: no version argument; run it explicitly with conformance/run.sh"
elif [ ! -x "$ROOT/candor-spec/conformance/run.sh" ]; then
  bad "candor-spec/conformance/run.sh is missing or not executable — the floor claim cannot be backed"
else
  # ── REUSE A GREEN RESULT ONLY WHEN NOTHING THAT COULD CHANGE IT MOVED ─────────────────────────────
  # A release runs this at least twice — `release.sh` re-runs preflight at step 0, and step 6's manual
  # pin bump forces a second invocation. On 0.28.1 it ran SIX times, of which at most two were over
  # changed inputs: ~330s each, most of it re-deriving an answer already known.
  #
  # THE LIST BELOW ENUMERATES WHAT LICENSES A SKIP, and that direction is the whole safety argument.
  # The instinct is to list what is RELEVANT (the engines, the suite) and skip when none of it changed;
  # that is unsafe, because forgetting one relevant path means skipping wrongly, silently, forever.
  # Listing what is IRRELEVANT inverts the failure: forget something and you run conformance you did not
  # need to — five minutes, never a false green. (Note this is the OPPOSITE of the classifier's
  # denylist-over-allowlist rule, because here SKIPPING is the dangerous act, not reporting.)
  #
  # Anything not on this list — any engine source, the suite, SPEC.md, the ledger — forces the full run.
  # So does a DIRTY tree (the recorded SHAs then describe something that is not what is on disk), a
  # missing or unreadable stamp, and any repo whose diff cannot be computed.
  # A1 — `(^|/)README\.md$` LICENSED SKIPPING A FILE THE SUITE READS. `must_ledger.py` builds the text a
  # ledger `part` value must resolve in from every `*.py`, `*.sh` AND `README.md` under conformance/, and
  # run.sh fails on an unresolvable reference. So a conformance/README.md edit that breaks the ledger was
  # licensed as "release mechanics" and the whole suite skipped — a FALSE GREEN, in the block that argues
  # at length that this direction can only ever cost a wasted run. The exclusion comes FIRST and wins:
  # anything under conformance/ is suite input, whatever its name.
  # A3 — the jbang entry was `^candor-java/jbang-catalog\.json$`, but `git -C <repo> diff --name-only`
  # emits REPO-relative paths, so it never matched and the step-6 re-run paid the full suite anyway. Dead
  # in the fail-safe direction, which is why nothing reported it.
  SKIP_NEVER='^conformance/'
  # A4 — THE PIN BUMP PAID FOR THE WHOLE SUITE. Step 6 rewrites the IDE plugin pins and (sometimes) the
  # release scripts themselves; neither was licensed, so re-entering release.sh for step 7 ran the full
  # four-way suite again. Measured on the 0.30.0 cut: 11 minutes, out of a 30-minute release. The suite
  # reads none of these — its only `integrations/` references are prose about FIX-SPEC.md, and it never
  # invokes anything in bin/ — so a change to them cannot alter a conformance result. Named explicitly
  # rather than licensing `^bin/` or `^integrations/` wholesale: an unlisted path only ever costs a
  # wasted run, so the conservative direction here is the SHORT list.
  SKIP_LICENSED='(^|/)CHANGELOG\.md$|^adopt/|^docs/|(^|/)README\.md$|^jbang-catalog\.json$|^bin/candor$|(^|/)BACKLOG\.md$'
  SKIP_LICENSED="$SKIP_LICENSED"'|^integrations/vscode/package\.json$|^integrations/jetbrains/gradle\.properties$'
  # …and CI workflow files. The suite runs local binaries against local fixtures and reads nothing under
  # .github/ (verified: zero references in run.sh or any generator). Whether CI is healthy is check [10]'s
  # question, asked against the live API; it is not evidence about the four-way contract. Left unlicensed,
  # every workflow edit in any of seven repos bought a full suite run — this file's own publish-workflow
  # fix did exactly that, ten minutes, while being measured.
  SKIP_LICENSED="$SKIP_LICENSED"'|(^|/)\.github/'
  SKIP_LICENSED="$SKIP_LICENSED"'|^bin/release\.sh$|^bin/release-stage\.sh$|^bin/release-verify\.sh$|^bin/release-preflight\.sh$|^bin/changelog-lag\.sh$|^bin/ci-watch\.sh$|^bin/verify-local\.sh$|^bin/spec-bump\.sh$'
  STAMP="$ROOT/candor-spec/conformance/.last-green-shas"
  reuse=1; why=""
  if [ ! -f "$STAMP" ]; then reuse=0; why="no recorded green run"; fi
  for r in candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor; do
    [ "$reuse" = 1 ] || break
    [ -d "$ROOT/$r/.git" ] || continue
    if [ -n "$(git -C "$ROOT/$r" status --porcelain)" ]; then reuse=0; why="$r has uncommitted changes"; break; fi
    was="$(grep -E "^$r " "$STAMP" 2>/dev/null | awk '{print $2}')"
    now="$(git -C "$ROOT/$r" rev-parse HEAD)"
    [ -n "$was" ] || { reuse=0; why="$r absent from the stamp"; break; }
    [ "$was" = "$now" ] && continue
    changed="$(git -C "$ROOT/$r" diff --name-only "$was" "$now" 2>/dev/null)" \
      || { reuse=0; why="$r: cannot diff $was..$now"; break; }
    [ -n "$changed" ] || continue
    # SKIP_NEVER is applied first and cannot be overridden by a licence: a path under conformance/ forces
    # the run even when its name also matches the licensed set.
    unlicensed="$(printf '%s\n' "$changed" | grep -E "$SKIP_NEVER" | head -3)"
    [ -z "$unlicensed" ] && unlicensed="$(printf '%s\n' "$changed" | grep -vE "$SKIP_LICENSED" | head -3)"
    [ -z "$unlicensed" ] || { reuse=0; why="$r changed $(printf '%s' "$unlicensed" | tr '\n' ' ')"; break; }
  done

  if [ "$reuse" = 1 ]; then
    ok "conformance REUSED — every change since the last green run is release mechanics (changelogs, pins, docs)"
    info "   the recorded run: $(head -1 "$STAMP" 2>/dev/null | sed 's/^# //')"
  elif ( cd "$ROOT/candor-spec/conformance" && ./run.sh ) >"$CONF_LOG" 2>&1; then
    ok "conformance OK ($(grep -c MATCH "$CONF_LOG") MATCH) — see $CONF_LOG${why:+  [ran: $why]}"
    # Record what was green, so the NEXT invocation can tell whether anything that matters moved.
    # A5 — DO NOT STAMP A DIRTY TREE. The read path refuses to reuse when a repo has uncommitted changes;
    # the write path had no such guard, so a green produced over HEAD+edits was recorded against the bare
    # HEAD sha. Stash or revert, run preflight again, and every sha matches — reuse then asserts a green
    # for a state the suite never ran against. The honesty of the stamp cannot live on one side only.
    stamp_dirty=""
    for r in candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor; do
      [ -d "$ROOT/$r/.git" ] || continue
      [ -n "$(git -C "$ROOT/$r" status --porcelain)" ] && stamp_dirty="$stamp_dirty $r"
    done
    if [ -n "$stamp_dirty" ]; then
      rm -f "$STAMP"
      info "   not recording a reuse stamp — this run covered uncommitted changes in$stamp_dirty"
    else
    { echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ) conformance green"
      for r in candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor; do
        [ -d "$ROOT/$r/.git" ] && echo "$r $(git -C "$ROOT/$r" rev-parse HEAD)"
      done; } > "$STAMP"
    fi
  else
    bad "conformance FAILED — see $CONF_LOG. The floor is conformance-pinned; do not publish"
    rm -f "$STAMP"   # never let a failed run leave a stamp a later invocation could reuse
  fi
fi

# ── [12] THE SPEC MAY NOT DESCRIBE A RUNG ABOVE ITS OWN DECLARED VERSION ───────────────────────────
# ⟨0.31⟩ was built four-way and held, because one of its two halves is NON-ADDITIVE: candor-rust's
# unevaluable-target refusal turns an exit 0 into an exit 2. A routine candor-rust publish would have
# shipped that flip under a floor whose §3.3 enumerates THREE exit-2 causes, and NOTHING here would have
# objected — conformance is green (PART 56 pins the NEW behaviour), CI is green, the changelogs are
# staged. Every gate in this script was looking at whether the tree is internally consistent. None was
# looking at whether the tree has outgrown the version it declares.
#
# That is what this check is: SPEC.md carries a rung marker on every clause, so the highest marker in the
# file is the highest rung the text describes. If it exceeds the version the same file declares, the spec
# has been written ahead of its number and a cut here would publish behaviour under a contract that does
# not mention it. The remedy is always the same and is never "ignore this": run `spec-bump.sh`.
#
# It takes no version argument on purpose, so it also fires in HEALTH MODE — the hold this encodes was
# being carried by a paragraph in BACKLOG.md and a line in my memory, both of which are only as good as
# whoever reads them before typing `release.sh`.
echo "[12] no rung is described above the declared spec version"
MAXRUNG="$(grep -oE '⟨0\.[0-9]+⟩' "$ROOT/candor-spec/SPEC.md" 2>/dev/null \
           | sed -E 's/⟨0\.([0-9]+)⟩/\1/' | sort -n | tail -1)"
FLOORMINOR="${SPEC_FLOOR#*.}"
if [ -z "${MAXRUNG}" ] || [ -z "$FLOORMINOR" ]; then
  bad "could not read a rung marker or a declared version out of SPEC.md — this check would pass over nothing"
elif [ "${MAXRUNG}" -gt "$FLOORMINOR" ]; then
  bad "SPEC.md declares Version ${SPEC_FLOOR} but describes ⟨0.${MAXRUNG}⟩ — the text is AHEAD of its number.
      Publishing now ships ⟨0.${MAXRUNG}⟩ behaviour under the ${SPEC_FLOOR} contract, which does not describe it.
      Run \`spec-bump.sh 0.${MAXRUNG}\` and cut that, or move the ⟨0.${MAXRUNG}⟩ clauses back out of SPEC.md."
else
  ok "highest rung ⟨0.${MAXRUNG}⟩ is within the declared ${SPEC_FLOOR}"
fi

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
