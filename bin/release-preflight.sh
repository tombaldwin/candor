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
#   bash bin/release-preflight.sh 0.32 0.32.1 --only candor-java   # a SCOPED cut: judge only that repo
#
# `--only <repos>` (comma- or space-separated; short forms spec/rust/java/ts/swift/agents/umbrella) says
# which repos the release covers. Without it the set is the whole family and every check is unchanged.
# With it, the version-shaped checks — [3] pins, [4] build constants, [6] crate deps, [7] the java jar,
# [9] `## Unreleased`, [10] CI — are asked of the cut set and reported `⊘ out of scope` for the rest;
# [1] the declared spec, [2] stale spec strings, [5]/[5b] the changelogs, [8] the script repo lists and
# [11] four-way conformance stay FAMILY-WIDE, because those are claims a one-engine patch still makes.
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
# THE CUT SET. `--only candor-java` scopes the version-shaped checks to the repos a patch actually
# publishes; with no flag the set is the whole family and every check is exactly the one it was. See
# bin/_release_set.sh for why a scoped cut cannot move ENGINE_PIN.
# shellcheck source=bin/_release_set.sh
. "$HERE/_release_set.sh"
rs_split_args "$@"
set -- "${RS_ARGS[@]+"${RS_ARGS[@]}"}"
rs_init
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
# OUT OF SCOPE is its own verb, and it is neither a pass nor a failure. A scoped cut must never print a
# ✔ for a question it did not ask — that is how "release-preflight: OK" would come to cover things it
# never looked at. `⊘` says the check exists, names its subject, and says which invocation asserts it.
oos()  { echo "  ⊘ $*"; }
rs_banner note

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
# `[0-9]:ok "` IS THIS FAMILY'S OWN ASSERTION VERB, and the list of ENGLISH WORDS could not see it. The
# umbrella's shell harnesses assert with a helper literally named `ok` — `ok "two units, one name" '[ … ]'`
# — so a row PINNING the prior floor read as prose. Anchored on `<lineno>:ok "` rather than the bare word,
# because `ok` as a substring is in `token`, `look` and `broken`: unanchored it would call almost every
# line an assertion. MEASURED over the family at this cut: it reclassifies NOTHING today (the shape does
# not currently exist), so it is a hole closed before it is stepped in rather than a fix for a live miss —
# and its direction is advisory→LOUD, which costs noise and never silence.
ASSERTION_RE='([0-9]:ok "|want|assert|assert_eq|expect|check|XCTAssert|toBe|toEqual|deepEqual|should)'
# The SUFFIX form was missing: this matched `test-foo.sh` but not `foo-test.sh`, so `bin/release-test.sh`
# — a file whose entire job is to BUILD a fixture changelog at the prior version — was reported as a
# shipped-source bump-miss on every cut. A fixture flagged as a defect trains the reader to skim the list
# that exists to be read.
#
# `[a-z-]*`, NOT `[a-z]*` — ONE HYPHEN, and it split one file's fixtures down the middle. The prefix form
# reached `test-foo.sh` and stopped at the SECOND hyphen, so `integrations/github/test-candor-sarif.sh`
# was not a fixture path. That file builds two kinds of document side by side: report envelopes, which
# CONSTRUCT_RE below recognises (`{"candor":`) and correctly called advisory, and GATE VERDICTS, which it
# does not (`{"spec":"0.32","ok":false,…`). Same file, same purpose, same deliberateness — 9 lines
# reported as a bump-miss and 35 beside them not, decided by which envelope shape a regex happened to
# know. Its `"spec":"0.7"` and `"spec":"0.8"` fixtures have ridden out every bump since 2026-07 unflagged,
# which is the control: they are only quiet because they are not the IMMEDIATELY-prior floor.
#
# WIDENING THIS IS THE SILENCING DIRECTION, so it was measured rather than argued. Over all seven repos at
# the 0.33 cut it moves exactly those 9 lines from loud to advisory and nothing else, and the fence still
# holds: ADVISORY requires fixture-path AND NOT an assertion, so an `assert_eq … "0.32"` (or, now, an
# `ok "…" '[ … "0.32" … ]'`) in that very file stays LOUD — falsified against both spellings, plus a
# shipped constant, a README claim and an adopt/ pin, all of which stay loud.
FIXTURE_PATH_RE='(^|/)(tests?|fixtures?|conformance)/|/tests?[.]|test[-_.][a-z-]*[.](mjs|py|sh|rs|js)|[-_.]test[.](mjs|py|sh|rs|js)|src/tests[.]rs|[.]test[.]'
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
  # WHOSE VERSION DOES THIS PIN NAME? Each of these names exactly ONE engine's release, so a cut moves
  # the pins whose owner it publishes and no others — demanding $VER from a pin naming an engine this
  # cut is not touching asks for a version that will never exist. (Family-wide: every owner is in the
  # set, so every pin is asserted, exactly as before.) ENGINE_PIN is the exception and the reason the
  # umbrella cannot ride a subset cut: it is a single value used for the java tag, `cargo install
  # --version`, `npx candor-ts@…` and the swift tag alike, so no subset can move it.
  local pin_owner; pin_owner="$(rs_pin_owner "$1")"
  if [ "$pin_owner" = '*family*' ]; then
    rs_is_full || { oos "$1: not moved by a scoped cut — it names the FAMILY line, which only a family-wide release can move"; return; }
  else
    rs_in_set "$pin_owner" || { oos "$1: not moved by this cut (it names $pin_owner, which is not being published)"; return; }
  fi
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
# ⟨2026-08-25⟩ …AND THE PER-ENGINE FRONT-DOOR PINS BESIDE ENGINE_PIN. These cannot go through `checkpin`:
# it asks "does the matched LINE contain $VER", and the correct value of an untouched per-engine pin is
# the EMPTY STRING (follow the family). So they are asserted on the RESOLVED version instead — what
# `candor update` would actually fetch — by the same rule release.sh step 7 refuses on, so the gate before
# the cut and the gate during it cannot disagree. Anything else is how a release passes preflight and dies
# at step 7, or worse, passes both while the front door names a release nobody made.
_DISP="$ROOT/candor/bin/candor"
if [ ! -f "$_DISP" ]; then
  bad "front door: no candor/bin/candor — the version \`candor update\` installs is unverifiable"
elif ! rs_in_set candor; then
  for _e in $RS_PIN_ENGINES; do
    oos "engine pin $_e: $(rs_engine_pin "$_e" "$_DISP") — the umbrella is not in this cut, so the front door does not move"
  done
else
  for _e in $RS_PIN_ENGINES; do
    _repo="$(rs_pin_repo "$_e")"; _p="$(rs_engine_pin "$_e" "$_DISP")"
    if rs_in_set "$_repo"; then
      if [ -z "$WANT_VER" ] || [ "$_p" = "$WANT_VER" ]; then note "engine pin $_e: $_p"
      elif [ -n "${PINS_ADVISORY:-}" ]; then info "engine pin $_e: still $_p — expected pre-publish, must be $WANT_VER after"
      else bad "engine pin $_e: $_p, not $WANT_VER — \`candor update\` would keep installing $_p for $_repo (update AFTER the release is published)"; fi
    elif [ -n "$WANT_VER" ] && [ "$_p" = "$WANT_VER" ]; then
      # NOT advisory-exempt, in either direction. A pin naming a version its repo is not publishing is
      # wrong BEFORE the cut and wrong after it — there is no moment at which that release appears.
      bad "engine pin $_e: names $WANT_VER, but $_repo is not in this cut — that release will never exist, so \`candor update\` would 404"
    else
      note "engine pin $_e: $_p (follows the family line; $_repo is not in this cut)"
    fi
  done
fi

# --- 4. self-declared BUILD versions agree (the hand-maintained constants, not the manifest) ------------
# The 0.17 bump moved pyproject/package/Cargo but missed the agents `VERSION = "agents-0.16.0"` constant
# (a SEPARATE literal in scan.py that stamps --version + the --agents header). swift's engineVersion is the
# same shape. These aren't derived from the manifest, so a bump has to touch each — assert they all agree.
echo "[4] self-declared build versions agree (hand-maintained constants vs the manifest)"
declare -a builds=()
# …and the subset of those that THIS CUT is publishing. The equality arm below asserts against the
# requested version, and a repo the cut does not touch legitimately stays on the previous one — asking
# it to carry $VER is asking for the lockstep this project's own §2.1 note says is not required.
declare -a set_builds=()
grabver() { # $1 label ; $2 file ; $3 regex ; $4 owning repo
  local f="$ROOT/$2"; [ -f "$f" ] || return
  local v; v="$(grep -oE "$3" "$f" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$v" ] && { note "$1: $v"; builds+=("$v"); rs_in_set "$4" && set_builds+=("$v"); }
}
grabver "agents VERSION" "candor-agents/candor_agents/scan.py"            'VERSION *= *"agents-[0-9.]+'     candor-agents
grabver "agents pyproj " "candor-agents/pyproject.toml"                   'version *= *"[0-9.]+'            candor-agents
grabver "swift engine  " "candor-swift/Sources/candor-swift/main.swift"   'engineVersion *= *"candor-swift-[0-9.]+' candor-swift
grabver "ts package    " "candor-ts/package.json"                         '"version": *"[0-9.]+'           candor-ts
grabver "rust crate    " "candor-rust/crates/candor-query/Cargo.toml"     'version = "[0-9.]+'              candor-rust
grabver "umbrella      " "candor/bin/candor"                             'UMBRELLA_VERSION="[0-9.]+'       candor
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
if [ -n "$WANT_VER" ]; then
  if [ "${#set_builds[@]}" -gt 0 ]; then
    # The suffixes are EMPTY family-wide, so a full cut's output is byte-identical to what this check
    # has always printed. A scoped run says which set it judged, because "build versions == 0.32.1" over
    # one repo and over seven are different claims and must not read the same.
    _sfx_bad=""; _sfx_ok=""
    rs_is_full || { _sfx_bad=" in the cut set"; _sfx_ok=" (cut set: $RS_SET)"; }
    printf '%s\n' "${set_builds[@]}" | grep -qxv "$WANT_VER" \
      && bad "a build version$_sfx_bad != requested $WANT_VER" \
      || ok "build versions == requested $WANT_VER$_sfx_ok"
  else
    # A CUT WHOSE REPOS HAVE NO HAND-MAINTAINED CONSTANT, which is the ordinary case for a candor-java
    # patch: java's build id is generated from the git hash (see the note above), so this check has
    # nothing to assert and must SAY so rather than print a ✔ over an empty comparison. [7] is where
    # java's version is actually gated.
    oos "no hand-maintained build constant in the cut set ($RS_SET) — nothing for this check to assert; [7] gates candor-java's"
  fi
fi

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
if [ -n "$WANT_VER" ] && ! rs_in_set candor-rust; then
  # The failure this exists to stop is `cargo publish` dying mid-sequence. A cut that publishes no crate
  # never runs that sequence, and candor-rust's manifests correctly still require the version it last
  # shipped — asserting $WANT_VER here would demand a crates.io version this cut is not creating.
  oos "candor-rust is not in this cut — no crate is published, so there is no publish sequence to protect"
elif [ -n "$WANT_VER" ]; then
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
if ! rs_in_set candor-java; then
  # `release.sh` step 3 only demands the jar for a cut that publishes candor-java. Outside the set the
  # gradle version legitimately names the last release, and the jar for THIS version was never built.
  oos "candor-java is not in this cut — its gradle version (${JGRADLE:-unreadable}) names the release it last shipped"
elif [ -z "$JGRADLE" ]; then bad "candor-java/build.gradle.kts: no top-level version found"
elif [ -n "$WANT_VER" ] && [ "$JGRADLE" != "$WANT_VER" ]; then
  bad "candor-java gradle version is $JGRADLE, not $WANT_VER — release.sh needs candor-java-$WANT_VER-all.jar and dies without it"
else ok "gradle version $JGRADLE"; fi
# …AND THE JAR MUST ACTUALLY EXIST. The check above compares a version STRING; `release.sh` step 3 then
# needs the FILE, and it is the third step — after crates.io (unyankable) and the npm tag. A never-built
# jar therefore kills the publish PART-WAY, with the earlier artifacts already out. That is the same
# distinction release-verify.sh's own header is about: a pin naming a URL is not the URL existing, and a
# version naming a jar is not the jar existing.
if [ -n "$WANT_VER" ] && rs_in_set candor-java; then
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

echo "[7b] every job in every CI workflow declares a timeout"
# A workflow with no `timeout-minutes` inherits GitHub's SIX-HOUR default. On 2026-08-19 two hung for
# 3h45m with no log output and were given a deadline — and their four siblings were not, so `ci.yml`
# then hung for 54 minutes against an ~11-minute median, stalling this very gate ([10] reads CI green on
# HEAD) while looking indistinguishable from a slow job. Fixing the workflows that failed and not the
# ones beside them is the habit this family keeps finding in its own engines; this makes the omission
# impossible to leave behind, because it asks EVERY file in EVERY repo rather than the ones that broke.
#
# PER JOB, not per file. The original check was `grep -q timeout-minutes "$wf"` — a STRING search over
# the whole file, which is satisfied by ANY job declaring one. That is exactly the shape it missed:
# candor's own jetbrains.yml has two jobs, `build` (timeout-minutes: 30) and `plugin-verifier` (none),
# and the file-level grep matched on the first and never looked at the second. Found by code review, not
# by this gate, on 2026-08-26. Reusable-workflow call jobs (a job whose body is `uses: ...`) are exempt:
# GitHub does not accept `timeout-minutes` there — the deadline lives in the CALLED workflow instead.
MISSING=""
if command -v python3 >/dev/null 2>&1; then
  for r in $WFREPOS; do
    for wf in "$ROOT/$r"/.github/workflows/*.yml "$ROOT/$r"/.github/workflows/*.yaml; do
      [ -e "$wf" ] || continue
      m="$(python3 - "$wf" <<'PYEOF' 2>/dev/null
import sys, yaml
path = sys.argv[1]
try:
    doc = yaml.safe_load(open(path)) or {}
except Exception as e:
    print("PARSE_ERROR: " + str(e))
    sys.exit(0)
jobs = doc.get("jobs") or {}
missing = [name for name, job in jobs.items()
           if isinstance(job, dict) and "uses" not in job and "timeout-minutes" not in job]
print(" ".join(missing))
PYEOF
)"
      case "$m" in
        PARSE_ERROR:*) MISSING="$MISSING $r/$(basename "$wf")[unparseable — ${m#PARSE_ERROR: }]" ;;
        "") : ;;
        *) for j in $m; do MISSING="$MISSING $r/$(basename "$wf"):$j"; done ;;
      esac
    done
  done
else
  MISSING="(skipped — no python3 on PATH, cannot parse job-level YAML)"
fi
if [ -n "$MISSING" ]; then
  bad "job(s) with no \`timeout-minutes\` — a hang there blocks a release for up to 6 hours and reads as slow:$MISSING"
else
  ok "every job in every workflow in every released repo declares a timeout"
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
# THE CUT SET, not the family. Content under `## Unreleased` in a repo this cut is NOT publishing is the
# normal staged state — the very thing the WANT_VER guard above exists to tolerate in health mode. A
# java-only patch must not be blocked by pending rust work that is going out on the next family rung.
for r in $RS_SET; do
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

# ── [9b] …AND THE VERSION BEING CUT MUST HAVE A SECTION OF ITS OWN ────────────────────────────────
# [9] above is only HALF the question. It asks whether anything is stranded UNDER `## Unreleased`; it has
# nothing to say about the case where that section is EMPTY — which it reads as fine, because nothing
# unlabelled ships. But an empty section meant `_stage_changelogs.py` produced NO `## [$VER]` heading,
# and `release.sh` then fell through to "the newest non-empty section" — i.e. published THE PREVIOUS
# VERSION'S NOTES under the new tag, silently. So the state [9] certifies as clean was the exact state
# that mis-published. Both halves of the release tooling went green over it.
#
# MEASURED THREE TIMES. candor-swift's and candor-agents' `## [0.29.1]` entries read, verbatim, "**Family
# build bump only — no engine changes in this repo**" and say in the entry itself that they were
# hand-written only because an empty section would otherwise republish the previous notes. It was hit
# again twice on 2026-08-25 — once before the 0.32.0 cut, and once after it, when all seven repos sat
# with an empty `## Unreleased` and a family-wide 0.32.1 would have republished 0.32.0's notes in six.
#
# THE QUESTION IS THE PUBLISHER'S, BYTE FOR BYTE. This check calls `bin/_release_notes.sh` — the same
# program `release.sh` uses to pick the body — rather than re-deriving "does a heading exist". A gate
# that asks its own version of the publisher's question is a gate that can go green on a cut that then
# refuses (or, worse, green on one that publishes something else). It also means the umbrella's dated
# arm, candor-spec's floor-shaped headings and the `(released … as $VER)` stamp are all covered here
# without this file knowing about any of them.
echo "[9b] the version being cut has release notes of its own${WANT_VER:+ ($WANT_VER)}"
if [ -z "$WANT_VER" ]; then
  note "— skipped: no version argument. Nothing is being cut, so no version needs a section yet"
else
  n_any=0
  for r in $RS_SET; do
    f="$ROOT/$r/CHANGELOG.md"
    [ -f "$f" ] || { bad "$r: no CHANGELOG.md — release.sh will refuse to publish it with no notes"; n_any=1; continue; }
    if nerr="$(bash "$HERE/_release_notes.sh" "$r" "${WANT_SPEC:-${SPEC_FLOOR:-}}" "$WANT_VER" "$f" 2>&1 >/dev/null)"; then :
    else
      n_any=1
      bad "$r: $nerr"
    fi
  done
  [ "$n_any" = 0 ] && ok "every repo in the cut has a \`$WANT_VER\` section — release.sh will publish ITS notes, not the last release's"
fi

# THE EIGHTH FALSE GREEN's fallback-route twin (2026-08-29, adversarial review). The NONE-branch inside
# [10] below asks an INFORMATIONAL question that has no commit to filter by at all: "is this repo's last
# known CI state green, across every workflow it has". That used to be one unfiltered `gh run list --limit
# 30` — a single page shared by the WHOLE repo's run history. A chatty sibling workflow (a 10-minute cron,
# a matrix job that reruns often) can fill all 30 slots by itself, and a quiet workflow's real, permanent
# `completed/failure` is then not merely listed and ignored — it is never RETURNED at all. Reproduced
# directly against bin/_ci_verdict.py: a synthetic 30-row page of one noisy workflow's runs, containing
# NOTHING of a second, quiet workflow's real permanent failure, prints "OK".
#
# THE FIX, same mechanism as bin/ci-watch.sh's fetch_earlier_commit_rows() (see its own header for the
# full argument — not copied verbatim here because that one already has WF_PATH_MAP and gh_call() built
# up around it from three other fixes, and forcing a shared abstraction across a bash script and this one
# would cost more clarity than it returns): enumerate this repo's own workflow ids via `gh workflow list`
# and fetch each one's OWN newest run on its OWN one-row page. A noisy sibling has no shared limit left to
# fill, so a quiet workflow's real state cannot be aged off a page it no longer shares with anything.
#
# Returns 1 (and prints nothing) if the workflow list itself could not be read — "could not enumerate this
# repo's workflows" is not the same claim as "every workflow enumerated is green", and the caller must not
# collapse the two.
ci_all_workflows_latest() {  # $1 = repo dir -> merged JSON array (each workflow's own newest run) on stdout
  local rd="$1" wf_out ids id one all=""
  wf_out="$(cd "$rd" && gh workflow list --json id -a --limit 100 2>/dev/null)"
  [ $? -eq 0 ] && [ -n "$wf_out" ] || return 1
  ids="$(printf '%s' "$wf_out" | jq -r '.[].id' 2>/dev/null)"
  [ -n "$ids" ] || return 1
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    one="$(cd "$rd" && gh run list --workflow "$id" --limit 1 \
           --json headSha,conclusion,status,workflowName,workflowDatabaseId,createdAt 2>/dev/null)"
    [ -n "$one" ] && all="$all
$one"
  done <<< "$ids"
  if [ -z "$all" ]; then
    printf '[]'
  else
    printf '%s\n' "$all" | jq -s 'add' 2>/dev/null
  fi
}

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
  # THE CUT SET. The question is "may I publish THIS commit of THIS repo", so a red CI in a repo the cut
  # does not publish is a real problem and someone else's — blocking a candor-java patch on candor-swift's
  # build would make the patch hostage to work it does not ship. Family-wide this is the same seven repos
  # it always was.
  for r in $RS_SET; do
    [ -d "$ROOT/$r/.git" ] || continue
    head_sha="$(git -C "$ROOT/$r" rev-parse HEAD 2>/dev/null)"
    # THE DEDUPE LIVES IN ONE PLACE: bin/_ci_verdict.py, called from both this initial read and the
    # post-wait re-check below. It used to be pasted twice — sorted by `createdAt`, which `gh` reports at
    # WHOLE-SECOND granularity, so two runs tied on that second had their "last write wins" merge pick
    # whichever one happened to be listed SECOND in the input, not whichever was newest. Swapping the two
    # objects in the input JSON flipped the verdict on identical facts. Fixed by adopting bin/ci-watch.sh's
    # already-proven approach instead of writing a third independent one: never re-sort, trust `gh`'s own
    # newest-first order, and keep the FIRST occurrence per workflow ID (2026-08-29: this used to be
    # workflowName, which GitHub does not require to be unique across files — see _ci_verdict.py's own
    # header for the reproduction). `workflowDatabaseId` is requested below for exactly that reason.
    # THE EIGHTH FALSE GREEN (2026-08-29, adversarial review): `--limit 30` was ONE page shared by every
    # workflow the repo has, filtered by headSha only AFTER `gh` returned it. If HEAD's own run had already
    # scrolled off the 30 most recent runs REPO-WIDE — a noisy sibling workflow accumulating enough newer
    # runs of its own — `_ci_verdict.py` never saw it at all and read "NONE" (no run for this commit),
    # which the NONE branch below then treats as "matched no path filter" and falls back to reporting the
    # repo's LAST KNOWN state instead — silently substituting a different, older answer for a real one it
    # never got to see. `--commit` filters at the source instead of after a capped page: the runs come back
    # already scoped to this exact sha, so a noisy sibling's volume elsewhere in the repo's history cannot
    # push this commit's own runs out of the response. `--limit 100` is headroom for a commit that
    # triggered more workflows than this repo has ever needed a limit for; `--commit` is what actually
    # closes the gap, not the number.
    verdicts="$(cd "$ROOT/$r" && gh run list --commit "$head_sha" --limit 100 --json headSha,conclusion,status,workflowName,workflowDatabaseId,createdAt 2>/dev/null \
      | python3 "$HERE/_ci_verdict.py" "$head_sha" 2>/dev/null)"
    # IN-PROGRESS IS NOT A FAILURE, IT IS A NOT-YET. `release.sh` steps 2–3 push the release TAGS, which
    # start candor-ts's OIDC `publish` and candor-swift's `release` — so the very next invocation of this
    # script, which is the one that resumes at step 7, is GUARANTEED to see its own workflows running and
    # fail. Measured on 0.28.1: a whole cycle spent re-running the release for that.
    #
    # …and since 2026-08-25 candor-java's `native` too, which fires on `release: published`. That is a
    # THIRD run this check will wait on at the tail of a cut, ~4 minutes, and it is the cheap half of a
    # good trade: `native` ALSO runs on every push to `main` now, so by the time this step runs in RELEASE
    # mode it has already had to see a green native parity check on the very commit being cut. Before that
    # move the native/jar parity gate ran only after the release was published — on v0.32.0 it correctly
    # withheld two binaries that reported an empty scan at exit 0, but only once v0.32.0 was public, and
    # repairing it cost a whole second family cut. This step is where that now gets caught instead.
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
      # SAME HELPER AS THE INITIAL READ ABOVE — see the comment there and bin/_ci_verdict.py. Kept as one
      # call site each rather than one shared shell function around them, because the two loops differ in
      # everything BUT this line (one runs once, one polls); the call itself is now the only thing they
      # share, and it is literally the same file, not a copy that could drift. Including the eighth-false-
      # green fix above (`--commit`, not a shared `--limit 30` page) — same reasoning, same file.
      verdicts="$(cd "$ROOT/$r" && gh run list --commit "$head_sha" --limit 100 --json headSha,conclusion,status,workflowName,workflowDatabaseId,createdAt 2>/dev/null \
        | python3 "$HERE/_ci_verdict.py" "$head_sha" 2>/dev/null)"
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
          # THIRD SIBLING OF THE SAME FILTER, so it now shares bin/_ci_verdict.py too rather than
          # re-deriving a third `gh run list` reading — but the QUESTION differs from the other two call
          # sites, which is why it passes "" instead of $head_sha. The other two ask "is THIS commit's
          # own CI green"; there is no such commit here — HEAD triggered nothing — so this asks the
          # informational fallback instead: "is this repo's last known CI state green at all". The old
          # version answered that by taking element 0 of `gh run list` unfiltered — the single freshest
          # completed run, of WHATEVER workflow happened to finish most recently. That mixes unrelated
          # signals across a repo's several workflows (push CI, weekly cron, nightly bump): a stale,
          # unrelated workflow finishing green after the real CI workflow broke would report "last CI run
          # green" over a genuinely broken build. `_ci_verdict.py` with an empty head dedupes every
          # workflow's own latest completed run instead, so one green straggler cannot stand in for a red
          # one elsewhere. See _ci_verdict.py's header for the full argument.
          #
          # PER WORKFLOW, NOT ONE SHARED PAGE — see ci_all_workflows_latest()'s own header above for the
          # eighth false green this replaces (a chatty sibling workflow filling a `--limit 30` page and
          # aging a quiet workflow's real failure off it entirely, never returned at all).
          if raw="$(ci_all_workflows_latest "$ROOT/$r")"; then
            verdict="$(printf '%s' "$raw" | python3 "$HERE/_ci_verdict.py" "" 2>/dev/null)"
            # The anchor sha is DISPLAY ONLY — which commit was freshest overall, so the message still names
            # something concrete. It plays no part in the verdict above, which judges every workflow. Sorted
            # by createdAt because the merged array is now in per-workflow-fetch order, not gh's newest-
            # first order (each workflow contributes exactly one row here, fetched independently).
            anchor="$(printf '%s' "$raw" | python3 -c "
import json, sys
runs = json.load(sys.stdin)
runs.sort(key=lambda r: r.get('createdAt') or '', reverse=True)
print(runs[0]['headSha'][:7] if runs else 'none')" 2>/dev/null)"
          else
            # A DISTINCT SENTINEL, never the empty string: `_ci_verdict.py` itself can also legitimately
            # produce an empty verdict (a python crash on malformed JSON), and that case must still hit the
            # `ERR|""` arm below and set ci_bad — collapsing both meanings onto "" would silently swallow
            # THAT failure the moment this one exists to catch the other.
            ci_bad=1
            bad "$r: could not enumerate this repo's workflows to check its last known CI state — treat as NOT verified"
            verdict="ENUM_FAILED"
          fi
          case "$verdict" in
            OK) info "$r: HEAD matched no workflow path filter (pushed, docs-only); last known CI state ($anchor) is green across every workflow" ;;
            ENUM_FAILED) ;;   # already reported above — do not also fall into the ERR|"" arm for it
            NONE) ci_bad=1; bad "$r: HEAD triggered no workflow, and this repo has no completed CI run to fall back on at all" ;;
            ERR|"") ci_bad=1; bad "$r: HEAD triggered no workflow, and CI status could not be read" ;;
            BAD*) ci_bad=1; bad "$r: HEAD triggered no workflow AND the last known state is not all green — ${verdict#BAD }" ;;
          esac
        fi
        ;;
      ERR|"") ci_bad=1; bad "$r: could not read CI status — treat as NOT verified";;
      BAD*) ci_bad=1; bad "$r: ${verdicts#BAD }";;
    esac
  done
  # …and the count is DERIVED. It said "all 7" while the loop walked a hard-coded seven; with a cut set
  # the number changes, and a summary that names a count the run did not check is the shape this file's
  # own ⟨0.24⟩ note calls load-bearing.
  [ "$ci_bad" = 0 ] && ok "all $(rs_count) repos green on HEAD"
fi

# ── [11] THE FOUR-WAY CONFORMANCE SUITE MUST PASS ──────────────────────────────────────────────────
# The floor is CONFORMANCE-PINNED (SPEC §2 versioning policy), so publishing a floor whose suite has not
# been run publishes an unbacked claim. The standing checklist said "run it"; nothing enforced it, and a
# checklist step that is not a gate is a step that gets skipped on a busy day. Release mode only — the
# suite takes minutes, which is right for a publish and wrong for an everyday health check.
# DELIBERATELY NOT SCOPED BY `--only`. The floor is a CROSS-ENGINE claim: publishing one engine at a new
# build id still asserts that engine agrees with the other three at the floor, and a one-engine patch is
# exactly where a divergence gets introduced (it is the only change in the tree). Scoping this to the cut
# would make the cheapest release the least checked one. The reuse stamp already makes the common case
# free, and it keys on all seven repos.
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
  # The scope is part of the verdict, not a decoration. `release-preflight: OK` over one repo and over
  # seven are different statements; printing the same words for both is how the bare-invocation `OK` came
  # to be quoted as a release gate six times while nothing was staged.
  if rs_is_full; then echo "release-preflight: OK${FLOOR:+ (floor $FLOOR)}"
  else echo "release-preflight: OK${FLOOR:+ (floor $FLOOR)} — SCOPED CUT: $RS_SET only; the rest of the family was not judged"; fi
else
  echo "release-preflight: $fail check(s) FAILED — resolve before publishing"
fi
# NOT `exit "$fail"`. Now that it counts, exiting the count would make 256 failures exit 0 — a wrap to
# green, on the one script whose entire job is to stand between a defect and a publish.
[ "$fail" = 0 ] || exit 1
exit 0
