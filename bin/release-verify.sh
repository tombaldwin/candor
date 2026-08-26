#!/usr/bin/env bash
# release-verify — the post-publish smoke: confirm the PUBLISHED artifacts (crates.io, npm, GitHub releases)
# actually carry the version just shipped, and that a fresh `npx` of the published package reports the spec.
# Run AFTER publishing.   bash bin/release-verify.sh 0.10 0.10.0
#
# `--only <repos>` verifies a SCOPED cut: exactly the artifacts that cut published, and nothing else.
#   bash bin/release-verify.sh 0.32 0.32.1 --only candor-java
# A check whose subject is outside the set prints `⊘` and is neither passed nor failed — it is NOT
# weakened for the family form, which is unchanged and remains the standing front-door audit that
# `.github/workflows/release-audit.yml` runs weekly against ENGINE_PIN. The distinction matters: the two
# invocations answer different questions, and only the bare one may ever print "live everywhere".
set -u
HERE_V="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/_release_set.sh
. "$HERE_V/_release_set.sh"
rs_split_args "$@"
set -- "${RS_ARGS[@]+"${RS_ARGS[@]}"}"
rs_init
SPEC="${1:?usage: release-verify.sh <spec> <ver> [--only repos]   e.g. 0.10 0.10.0}"
VER="${2:?usage: release-verify.sh <spec> <ver> [--only repos]}"
# CANDOR_ROOT, like the other three release scripts. This was the only one of the four that could not be
# pointed at a FIXTURE tree, so the pin-reading half of it — which is where the 0.24 failure lived, a pin
# naming a release that did not exist — could only ever be exercised by publishing. The default is
# unchanged (the sibling directory this script sits in), and nothing in production sets the variable:
# `.github/workflows/release-audit.yml` runs the bare form against real checkouts.
ROOT_C="${CANDOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"   # the dir holding candor-* siblings
UA="candor-release-verify (tom@polymorphism.co.uk)"   # crates.io 403s a UA-less request
fail=0; ok() { echo "  ✔ $*"; }
# OUT OF SCOPE — counted separately, and printed in the verdict. A scoped run that reported plain "OK"
# would be claiming the family form's answer while having asked a fraction of it.
oos_n=0; oos() { echo "  ⊘ $*"; oos_n=$((oos_n + 1)); }
# INCREMENT, do not assign — this was `fail=1`, so the summary reported one failure no matter how many
# fired. Same defect release-preflight carried. The number is what tells you whether the last fix helped.
bad() { echo "  ✘ $*"; fail=$((fail + 1)); }
note() { echo "  · $*"; }

echo "[crates.io] the four crates at $VER"
if ! rs_in_set candor-rust; then oos "candor-rust is not in this cut — no crate was published at $VER"
else
for c in candor-report candor-classify candor-query candor-scan; do
  v=$(curl -sSL -H "User-Agent: $UA" "https://crates.io/api/v1/crates/$c" 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["crate"]["max_version"])' 2>/dev/null)
  [ "$v" = "$VER" ] && ok "$c $v" || bad "$c: max_version '${v:-?}' != $VER"
done
fi

echo "[npm] candor-ts at $VER"
if ! rs_in_set candor-ts; then oos "candor-ts is not in this cut — npm still serves the version it last published"
else
v=$(npm view candor-ts version 2>/dev/null)
[ "$v" = "$VER" ] && ok "candor-ts $v" || bad "candor-ts: npm version '${v:-?}' != $VER"
fi

echo "[gh releases] spec v$SPEC · engines v$VER"
# candor-ts and the umbrella were MISSING from this list until 2026-08-01 — so a release could be declared
# live with neither cut, and on 0.24 candor-spec itself was found untagged only because it WAS listed here.
# candor-spec is tagged at the SPEC version (`v0.25`), not the engine build (`v0.25.0`) — the spec has no
# patch component, and `release.sh` cuts it as `rel candor-spec "v$SPEC"`. This line said `v$VER` for both,
# so the VERIFIER and the PUBLISHER disagreed on the tag name. It never surfaced at 0.24 only because the
# 0.24 cleanup hand-created a `v0.24.0` spec tag — the very thing the verifier was looking for — which
# masked the mismatch and left two tag schemes in the history (v0.25, v0.24.0, v0.23, v0.21.0 …).
# THE LITERAL LIST STAYS LITERAL. preflight [8] derives this script's repo set by grepping exactly the
# quoted repo:tag strings below and comparing them with `release.sh`'s `rel` lines — the check that caught
# …and it is greppable enough to be tripped by PROSE: the first draft of this very comment spelled an
# example `"candor-x:v` + `$VER"`, which [8] read as an eighth repo the verifier checks and the publisher
# does not. Left recorded rather than tidied away, because it is the same lesson one level up: the check
# is a text derivation, so anything shaped like the text is part of the list.
# the publisher cutting four releases while the verifier checked seven. Filtering at loop time keeps that
# derivation intact; rebuilding the list from a variable would empty it.
for r in "candor-spec:v$SPEC" "candor-rust:v$VER" "candor-java:v$VER" "candor-swift:v$VER" \
         "candor-agents:v$VER" "candor-ts:v$VER" "candor:v$VER"; do
  repo="${r%%:*}"; tag="${r##*:}"
  rs_in_set "$repo" || { oos "$repo: not in this cut — no $tag release was created"; continue; }
  # ONE gh call for both facts, not two adjacent ones. DEFECT (code review, 2026-08-26): the old code read
  # tagName and isDraft in separate calls, and if the SECOND one failed — network blip, secondary rate
  # limit; this loop already fires up to 14 back-to-back calls, and the incident that motivated the draft
  # check in the first place was full of gh 409s and 403s — `draft` came back empty, empty is not "true",
  # so it took the `ok` branch. A transient failure on the call that exists to catch drafts read as
  # "confirmed not a draft". Combining into one call halves the exposure; the branch below still treats a
  # failed call as its own outcome rather than folding it into "false".
  #
  # `-q` runs jq: emit "tagName|true" or "tagName|false". If the call fails outright (bad tag, network,
  # rate limit) it never reaches jq at all, so $info comes back EMPTY — never "|false" — which is what lets
  # the branches below tell "confirmed not a draft" apart from "could not determine".
  info=$(gh release view "$tag" -R "tombaldwin/$repo" \
           --json tagName,isDraft -q '(.tagName // "") + "|" + (if .isDraft then "true" else "false" end)' \
           2>/dev/null)
  got="${info%%|*}"; draft="${info#*|}"
  if [ -z "$info" ]; then
    bad "$repo: could not read release info for $tag at all (gh call failed — network blip, secondary rate limit, or the release genuinely does not exist) — treat as NOT VERIFIED, not as passing. Re-check by hand: gh release view $tag -R tombaldwin/$repo"
    continue
  fi
  if [ "$got" != "$tag" ]; then bad "$repo: release '${got:-missing}' != $tag"; continue; fi
  # DELETING A GIT TAG SILENTLY CONVERTS ITS GITHUB RELEASE TO A DRAFT, and a draft serves 404 on every
  # asset download URL EVEN THOUGH THE API REPORTS THE ASSET `state=uploaded` — the release itself, and
  # the tagName read above, look completely normal. Measured on 0.33.0: candor-swift's tag was deleted
  # and re-pushed to recover an orphaned workflow run, the binary built and attached fine, and every
  # consumer's `candor update` / direct download 404'd anyway. Checked here, not just in the artifact-URL
  # loop below, because a draft is the CAUSE and a 404 is only its symptom two sections down — naming the
  # cause is what turns "404, no idea why" into a one-command fix.
  case "$draft" in
    true)
      bad "$repo: $tag is a DRAFT release — a draft 404s on every asset URL regardless of what the API says about the asset's own state. Likely cause: the tag was deleted and re-pushed. Remedy: gh release edit $tag -R tombaldwin/$repo --draft=false" ;;
    false)
      ok "$repo $got" ;;
    *)
      # THE THIRD STATE, MADE LOUD. Reachable only if the call succeeded (tagName matched, so $info was
      # non-empty and well-formed) yet isDraft still failed to resolve to true/false — kept as its own
      # branch, distinct from the "call failed outright" case above, rather than folded into either
      # confirmed state.
      bad "$repo: $tag's draft status is UNREADABLE ('${draft:-empty}') even though its tag matched — treat as NOT CONFIRMED non-draft. Re-check by hand: gh release view $tag -R tombaldwin/$repo --json isDraft" ;;
  esac
done

# --- the pinned DOWNLOAD URLS actually resolve --------------------------------------------------------
# Added 2026-08-01, after the 0.24 release shipped with `jbang-catalog.json` and `bin/candor` pinned at
# v0.24.0 while the candor-java GitHub release did not exist — so every `candor update` and every jbang
# invocation got a 404 for the JVM engine. `release-preflight [3]` was GREEN throughout: it checks that the
# pin SAYS the right version, which is not the same question as whether the thing it names is there.
# A pin naming a URL is not the URL existing. Resolve the artifact, never just the string.
echo "[artifacts] the pinned download URLs resolve"
declare -a urls=()
# URLs whose OWNING pin this cut did not move. They are printed, never asserted and never resolved: they
# are the family form's subject, and this run is not the family form. Empty for a family-wide cut.
declare -a oos_urls=()
# derive from the pin files rather than hardcoding, so this tracks the pins instead of drifting beside them
jb="$ROOT_C/candor-java/jbang-catalog.json"
if rs_in_set candor-java; then
  [ -f "$jb" ] && while read -r u; do urls+=("$u"); done < <(grep -oE 'https://github\.com/[^"]+/releases/download/[^"]+' "$jb")
else
  [ -f "$jb" ] && while read -r u; do oos_urls+=("$u"); done < <(grep -oE 'https://github\.com/[^"]+/releases/download/[^"]+' "$jb")
fi
# what `candor update` fetches for the JVM front door. THE VERSION IS READ FROM `bin/candor`'s
# ENGINE_PIN, NOT FROM $VER — and that distinction is the whole point. Building these from $VER asks
# "does v$VER have assets?", which is not the question a consumer's machine asks: `candor update` fetches
# whatever ENGINE_PIN says, so a release that forgot to move the pin ships a working v$VER while every
# `candor update` keeps installing the OLD engine — the literal 0.18-engines-under-a-0.23-umbrella
# failure, which this verifier passed. Reading the pin makes the mismatch a FAILURE here rather than
# something only a strict re-run of preflight [3] would catch, and the documented post-publish path says
# "run release-verify", not "re-run preflight".
EPIN="$(rs_family_pin "$ROOT_C/candor/bin/candor")"
# THE PER-ENGINE PIN IS THE ONE THAT ANSWERS "what does `candor update` fetch for THIS engine". Since
# 2026-08-25 `bin/candor` carries a family pin plus an optional pin per engine, so the java URLs below
# must be built from JPIN, not from EPIN: with a java-only patch in effect they are different versions,
# and building them from the family line would resolve the assets of the release the patch REPLACED and
# call the front door verified.
JPIN="$(rs_engine_pin java "$ROOT_C/candor/bin/candor")"
#
# READING THE PIN IS UNCONDITIONAL: an unreadable pin is a fact about the file, not about the cut, and it
# is the one state in which nothing downstream can be trusted. The COMPARISON is directional, because
# this script has two callers with different questions. `release.sh` runs it after a cut, where a pin
# BEHIND $VER means the release did not reach the front door — the 0.18-engines-under-a-0.23-umbrella
# failure. `release-audit.yml` runs it weekly with $VER derived FROM the family pin, where an engine
# pinned AHEAD is the ordinary state after a one-engine patch and must not be a red monitor forever.
# So: behind → fail (family-wide); ahead → say so and carry on, with the artifacts still RESOLVED below,
# which is the check that actually protects a user.
if [ -z "$EPIN" ]; then bad "could not read ENGINE_PIN from candor/bin/candor — the front door's version is unverifiable"
elif [ "$EPIN" != "$VER" ] && rs_is_full; then
  bad "ENGINE_PIN is $EPIN, not $VER — \`candor update\` and \`candor init\` still install the OLD engine, whatever this release published"
elif [ "$EPIN" != "$VER" ]; then
  oos "ENGINE_PIN is $EPIN — this cut did not move the family line, so \`candor update\` and \`candor init\` keep installing the $EPIN line for every engine not pinned separately. Assert the front door with: release-verify.sh ${EPIN%.*} $EPIN"
fi
if [ -n "$JPIN" ] && [ "$JPIN" != "$EPIN" ]; then
  oos "the front door pins java SEPARATELY at $JPIN (family line $EPIN) — a one-engine patch. The java URLs below are resolved at $JPIN, which is what \`candor update\` fetches."
fi
for a in "candor-java-${JPIN:-$VER}-all.jar" candor-linux-x64 candor-macos-arm64; do
  if rs_is_full; then urls+=("https://github.com/tombaldwin/candor-java/releases/download/v${JPIN:-$VER}/$a")
  else oos_urls+=("https://github.com/tombaldwin/candor-java/releases/download/v${JPIN:-$VER}/$a"); fi
done
# …and for a SCOPED java cut, the release's OWN assets at $VER, which nothing else here would reach. The
# jbang pin names only the jar, so without this the two native binaries — the entire reason a java-only
# patch gets cut — would go unverified while the run printed OK. Added only when scoped: family-wide,
# ENGINE_PIN == $VER makes these the same three strings the loop above already built, and a full cut's
# output must stay exactly what it was.
if ! rs_is_full && rs_in_set candor-java; then
  for a in "candor-java-$VER-all.jar" candor-linux-x64 candor-macos-arm64; do
    urls+=("https://github.com/tombaldwin/candor-java/releases/download/v$VER/$a")
  done
fi
# THE adopt/ PINS ARE A CONSUMER-FACING SURFACE TOO, and nothing verified them at all: a repo that ran
# `candor init` gets these workflows committed, so a stale pin there installs the old engine in THEIR CI
# forever. Same question as ENGINE_PIN, different file.
# EACH adopt/ PIN NAMES ONE ENGINE, so the owner column decides whether this cut is answerable for it.
# `candor.yml`'s CANDOR_JAVA_VERSION is candor-java's; `candor-digest.yml`'s `candor-agents@v` is
# candor-agents'. A java-only patch moves the first and must not be asked about the second — demanding
# $VER there asks for an agents release that was never cut.
for pf in "candor/adopt/candor.yml:CANDOR_JAVA_VERSION:candor-java" "candor/adopt/candor-digest.yml:candor-agents@v:candor-agents"; do
  f="$ROOT_C/${pf%%:*}"; rest="${pf#*:}"; key="${rest%%:*}"; pin_repo="${rest##*:}"
  [ -f "$f" ] || continue
  pv="$(grep -oE "$key *:? *v?[0-9]+\.[0-9]+\.[0-9]+" "$f" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if ! rs_in_set "$pin_repo"; then oos "${pf%%:*} pins ${pv:-?} — names $pin_repo, which is not in this cut"
  elif [ -z "$pv" ]; then bad "${pf%%:*}: no $key pin found — a consumer-facing pin nothing verifies"
  elif [ "$pv" != "$VER" ]; then bad "${pf%%:*} pins $pv, not $VER — every repo that ran \`candor init\` keeps installing $pv"
  else ok "${pf%%:*} pins $VER"; fi
done
# NOT CHECKED HERE, AND SAYING SO IS THE POINT: the two IDE plugin pins (`candorTsVersion`,
# `candorJavaVersion`) are gated by preflight [3] BEFORE a cut and by nothing after one — in either mode,
# family-wide or scoped. That asymmetry predates the cut set and is left alone deliberately: closing it
# adds ✔ lines to the family form, and a change that alters what "release-verify: OK" covers for everyone
# does not belong inside a change whose whole contract is that the default is untouched.
# candor-swift's binary. THE GAP THIS CLOSES: every candor-swift release through v0.26.0 had ZERO assets
# — the workflow built, tested, smoked and cut the release, then attached nothing — and this verifier
# passed every one of them, because the release loop above only asks whether the RELEASE EXISTS. That is
# exactly the mistake the comment above warns about, made about a different repo: a release is not an
# installable artifact. The visible cost was `candor update` telling a Mac user to install a Swift
# toolchain and build from source, for the engine that owns the privacy manifest. Assets begin at 0.27;
# below that their absence is history rather than a regression, so it is noted and not failed.
# WHICH CUTS OWE A DOWNLOADABLE ARTIFACT AT ALL. Family-wide, always — that is the guard below as it has
# always stood. Scoped, it depends on the set: candor-java publishes a jar and two native binaries and
# candor-swift a binary, while candor-rust ships to crates.io, candor-ts to npm and candor-agents through
# `pipx install git+…@vX` — none of which is a release download this loop can resolve. Asserting "at
# least one URL" over an agents-only cut would fail it for a fact about the delivery channel, and a gate
# that fires on a correct state is one that gets waved through.
EXPECT_URLS=0
rs_is_full && EXPECT_URLS=1
rs_in_set candor-java && EXPECT_URLS=1
if ! rs_in_set candor-swift; then oos "candor-swift is not in this cut — no v$VER binary was published"
else
case "$VER" in
  0.1?.*|0.2[0-6].*) note "candor-swift: no binary asset expected before 0.27 (its workflow attached none)";;
  *) urls+=("https://github.com/tombaldwin/candor-swift/releases/download/v$VER/candor-swift-macos-arm64"); EXPECT_URLS=1;;
esac
fi
# THE EMPTINESS GUARD IS NOT WEAKENED FOR A SCOPED CUT THAT OWES AN ARTIFACT. "No URL to check" must stay
# a FAILURE for those, not a quiet pass: a `--only candor-java` that resolved nothing would otherwise
# print a clean OK having resolved nothing, which is precisely the shape this line was added to refuse.
if [ "$EXPECT_URLS" = 1 ] && [ "${#urls[@]}" -eq 0 ]; then bad "no pinned download URLs found — the check cannot have passed"; fi
if [ "${#oos_urls[@]}" -gt 0 ]; then
  for u in $(printf '%s\n' "${oos_urls[@]}" | sort -u); do
    oos "not this cut's artifact — ${u##*/} at $(printf '%s' "$u" | grep -oE '/v[0-9]+\.[0-9]+\.[0-9]+/' | tr -d /)"
  done
fi
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
if ! rs_in_set candor-ts; then oos "candor-ts is not in this cut — there is no candor-ts@$VER to smoke"
else
out=$(npx -y "candor-ts@$VER" --version 2>/dev/null | head -1)
echo "$out" | grep -q "spec $SPEC" && ok "$out" || bad "npx reported '${out:-<none>}' (expected spec $SPEC)"
fi

echo
# "LIVE EVERYWHERE" IS THE FAMILY FORM'S SENTENCE AND ONLY ITS SENTENCE. A scoped run has not looked at
# most of "everywhere", so it says what it did look at, how many questions it declined, and which
# invocation answers them — otherwise a green line from a one-repo run reads exactly like the release
# gate that stands behind a whole floor.
if [ "$fail" = 0 ] && rs_is_full; then echo "release-verify: OK — spec $SPEC / v$VER is live everywhere"
elif [ "$fail" = 0 ]; then
  echo "release-verify: OK — v$VER is live for: $RS_SET (spec floor $SPEC unchanged)."
  echo "  $oos_n check(s) OUT OF SCOPE — the rest of the family and the ENGINE_PIN front door were NOT verified."
  echo "  The front door is asserted by the family form: bash bin/release-verify.sh <spec> <ENGINE_PIN version>"
else echo "release-verify: $fail check(s) FAILED"; fi
[ "$fail" = 0 ] || exit 1   # NOT `exit "$fail"` — 256 failures would exit 0, a wrap to green
exit 0
