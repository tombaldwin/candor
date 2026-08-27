#!/usr/bin/env bash
# release.sh — one-command publish of a staged candor floor. Run it when you can grant the publish permissions
# (or from your own terminal). It assumes the version is ALREADY bumped + committed + pushed on every repo's main
# (that is `bin/release-preflight.sh`'s job); this script only PUBLISHES, in the order that has bitten us before.
#
#   bash bin/release.sh 0.22 0.22.0
#   bash bin/release.sh 0.32 0.32.1 --only candor-java     # a SCOPED cut — one engine, same spec floor
#
# `--only <repos>` publishes a SUBSET. The spec axis is untouched by it (a patch keeps the floor), no
# crate/npm/GitHub artifact is produced for a repo outside the set, and — see bin/_release_set.sh — the
# UMBRELLA cannot ride a subset cut, because ENGINE_PIN is one value for the whole family. So a scoped
# cut stops after step 6: the per-engine pins move, `candor update` keeps installing the family line.
#
# Idempotent-ish: a crate/release that already exists is skipped with a note, so a re-run after a mid-way failure
# resumes cleanly. Stops on the first UNexpected error. Needs: crates.io token (~/.cargo/credentials.toml), gh auth,
# and push access. npm needs NO local token — the candor-ts tag triggers the OIDC publish.yml (SLSA provenance).
set -uo pipefail
HERE_R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/_release_set.sh
. "$HERE_R/_release_set.sh"
rs_split_args "$@"
set -- "${RS_ARGS[@]+"${RS_ARGS[@]}"}"
rs_init
SPEC="${1:?usage: release.sh <spec e.g. 0.22> <version e.g. 0.22.0> [--only repos]}"
VER="${2:?usage: release.sh <spec> <version> [--only repos]}"
# CANDOR_ROOT lets the test harness point these at a FIXTURE tree instead of the real siblings.
# Without it neither script can be exercised without editing six live repos, which is why nine
# defects across 0.25 and 0.26 were found by publishing rather than by testing.
ROOT="${CANDOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"   # dir holding candor-* siblings
say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✔\033[0m %s\n' "$*"; }
skip(){ printf '  \033[33m•\033[0m %s\n' "$*"; }
die() { printf '  \033[31m✘ %s\033[0m\n' "$*"; exit 1; }

# --- 0. gate: preflight must be green + every main pushed ------------------------------------------------
say "0. preflight ($SPEC / $VER)"
rs_is_full || skip "SCOPED CUT: $RS_SET — no other repo is published, ENGINE_PIN and the umbrella stay on the family line"
# PINS_ADVISORY: check [3] asserts the cross-repo pins name $VER, and they cannot until this script has
# published $VER. Strict here is a deadlock, not a safeguard — see the note in release-preflight.sh. The
# pins are updated in step 6 below and then RESOLVED by release-verify.sh, which is the check that matters.
# CANDOR_ONLY is EXPORTED by rs_split_args, so preflight inherits the same set without this line having
# to reconstruct the flag — and a child that derived a DIFFERENT set from the parent is precisely the
# publisher/verifier disagreement check [8] exists for, one process boundary further down.
PINS_ADVISORY=1 bash "$ROOT/candor/bin/release-preflight.sh" "$SPEC" "$VER" >/tmp/rel-preflight.txt 2>&1 \
  && ok "release-preflight OK (cross-repo pins advisory — they move in step 6)" \
  || die "release-preflight FAILED — see /tmp/rel-preflight.txt"
# THE CUT SET, PLUS THE UMBRELLA — and the umbrella is not there out of habit. Step 6 edits pins that
# live in `candor/adopt/` and `candor/integrations/`, and step 7 may tag it, so it is a repo this run
# WRITES TO whatever the set says. Every other repo is untouched by a scoped cut, and demanding a clean
# tree in a repo the release never opens is the lockstep this flag exists to remove.
CLEAN_REPOS="$RS_SET"
case " $RS_SET " in *" candor "*) ;; *) CLEAN_REPOS="$RS_SET candor" ;; esac
for r in $CLEAN_REPOS; do
  [ -z "$(git -C "$ROOT/$r" status --porcelain)" ] || die "$r has uncommitted changes — commit + push first"
  [ "$(git -C "$ROOT/$r" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" = "0" ] || die "$r has unpushed commits — push main first"
done
ok "all mains clean + pushed"

# --- 1. crates.io — STRICT dep order (report → classify → scan → query) ----------------------------------
# cargo publish waits for index propagation of each dep before the next resolves. A crate already at $VER on
# crates.io errors "already uploaded" → we treat that as a skip and continue.
say "1. crates.io (dep order)"
if ! rs_in_set candor-rust; then skip "candor-rust is not in this cut — no crate is published"
else
cd "$ROOT/candor-rust" || die "cannot cd to $ROOT/candor-rust"
for crate in candor-report candor-classify candor-scan candor-query; do
  if cargo publish -p "$crate" 2>/tmp/rel-$crate.txt; then ok "published $crate@$VER"
  elif grep -qiE "already (uploaded|exists)|crate version .* is already" /tmp/rel-$crate.txt; then skip "$crate@$VER already on crates.io"
  else cat /tmp/rel-$crate.txt; die "cargo publish -p $crate failed"; fi
done
fi

# --- 2. candor-ts → npm via the tag-triggered OIDC action (never manual npm publish) ---------------------
say "2. candor-ts npm (via v$VER tag → OIDC publish.yml)"
if ! rs_in_set candor-ts; then skip "candor-ts is not in this cut — nothing is tagged, so nothing publishes to npm"
else
cd "$ROOT/candor-ts" || die "cannot cd to $ROOT/candor-ts"
# rs_tag_and_push checks ORIGIN, not the local ref — see its own comment in _release_set.sh for why a
# local check let a failed push go unretried across reruns and unreported on the run that failed it.
rs_tag_and_push "v$VER" ""; tprc=$?
case "$tprc" in
  3) skip "tag v$VER already on origin" ;;
  0) ok "tagged + pushed v$VER (OIDC action publishes candor-ts@$VER with provenance)" ;;
  *) die "candor-ts: v$VER did not reach origin — see the message above. candor-ts's OIDC publish never
     fires until the tag is on origin, so npm step 5/6's wait would fail for a workflow that was never
     triggered. Fix access/network and re-run — steps already done are skipped, this one retries." ;;
esac
fi

# --- 3. GitHub releases (java release triggers native.yml + needs the jar asset) -------------------------
say "3. GitHub releases"
JAR=""
if rs_in_set candor-java; then
  JAR="$(ls "$ROOT"/candor-java/build/libs/candor-java-"$VER"-all.jar 2>/dev/null || true)"
  [ -n "$JAR" ] || die "candor-java-$VER-all.jar not built — run ./gradlew shadowJar in candor-java first"
fi
rel() { # $1 repo ; $2 tag ; $3 title ; shift 3 ; extra assets
  local repo="$1" tag="$2" title="$3"; shift 3
  # THE SET IS ENFORCED HERE, NOT AT THE CALL SITES, and that is deliberate: preflight [8] derives the
  # published-repo list by grepping `^rel candor…` out of this file and compares it with the verifier's,
  # so wrapping the calls in `if` blocks would indent them out of that grep and silently empty the one
  # check that keeps the publisher and the verifier naming the same repos.
  if ! rs_in_set "$repo"; then skip "$repo is not in this cut — no release cut"; return 0; fi
  if gh release view "$tag" -R "tombaldwin/$repo" >/dev/null 2>&1; then skip "$repo $tag already released"
  else
    # SELECTION LIVES IN `bin/_release_notes.sh`, AND IT REFUSES RATHER THAN GUESSES.
    #
    # What used to be here ended in a silent FALL-THROUGH: no `## [$VER]` section → publish "the newest
    # non-empty section", which is THE PREVIOUS VERSION'S NOTES, under the new tag, announced by a yellow
    # `•` at the end of a long release. `_stage_changelogs.py` produces that state as a matter of course —
    # it skips an EMPTY `## Unreleased`, and a repo with nothing to say is exactly what a family build
    # bump is. Hit at 0.29.1 (two repos hand-wrote "Family build bump only" entries to dodge it), hit
    # again twice on 2026-08-25. Publishing the wrong notes is silent and reaches users; refusing is loud
    # and reaches one operator with a one-command remedy, so the fall-through is gone — see that file's
    # header for the umbrella's dated arm and the fence on it.
    #
    # The helper is a SEPARATE PROGRAM so `release-test.sh` drives the code that publishes rather than a
    # copy of it: the harness re-implemented this awk inline for three releases, which is the "a test that
    # bypasses the integration point is a test of the wrong thing" note two comments down in this file.
    # REDIRECTED STRAIGHT TO THE FILE, never through `notes="$(…)"`. Command substitution strips trailing
    # newlines, so a variable round-trip here silently changes the bytes published — the identical trap
    # this file's helper carries a comment about, one process boundary up. The helper writes NOTHING to
    # stdout when it refuses, so an empty file cannot be created by the failing branch either.
    if bash "$HERE_R/_release_notes.sh" "$repo" "$SPEC" "$VER" "$ROOT/$repo/CHANGELOG.md" \
         > "/tmp/rel-body-$repo.md" 2>"/tmp/rel-notes-$repo.err"; then :
    else die "$(cat "/tmp/rel-notes-$repo.err")"; fi
    # Belt and braces at the call site: the helper cannot return blank on exit 0, and if it ever did,
    # `gh release create -F` would happily publish an empty body.
    grep -q '[^[:space:]]' "/tmp/rel-body-$repo.md" || die "$repo: release notes are whitespace only — refusing"
    # `gh release create` can create the release and still fail — an asset upload rejected mid-way
    # (plausible for java's jar) leaves the release itself sitting there. A rerun's own guard, two lines
    # up (`gh release view`), then sees "already released" and skips — it never re-uploads. This DIES
    # rather than falling through silently, same shape as the tag-push fix above, and names the exact
    # remedy `gh release view` cannot: the release exists, only the asset does not.
    gh release create "$tag" "$@" -R "tombaldwin/$repo" -t "$title" -F "/tmp/rel-body-$repo.md" && ok "$repo $tag" \
      || die "$repo $tag: gh release create failed or a partial upload — check \`gh release view $tag -R tombaldwin/$repo\`.
     If the release exists but an asset is missing, re-upload it directly (a rerun of this script will
     NOT retry it, because the release already existing is the normal skip case):
       gh release upload $tag $* -R tombaldwin/$repo --clobber"
  fi
}
# ALL SEVEN, not four. This cut java/swift/agents/spec only, while `release-verify.sh` checks all seven —
# so candor-rust, candor-ts and the umbrella were TAGGED (ts by the npm step, the umbrella by step 4) and
# never released, and the verifier failed on repos the publisher was never asked to cut.
rel candor-java   "v$VER" "candor-java v$VER" "$JAR"
rel candor-swift  "v$VER" "candor-swift v$VER"
rel candor-agents "v$VER" "candor-agents v$VER"
rel candor-rust   "v$VER" "candor-rust v$VER"
rel candor-ts     "v$VER" "candor-ts v$VER"
# THE UMBRELLA IS NOT CUT HERE. Its tarball carries ENGINE_PIN, which step 6 has not moved yet — so a
# release cut at this point ships a $VER umbrella that fetches the PREVIOUS line's engines, and the brew
# formula hashes exactly that tarball. See step 7.
# the SPEC is tagged at its OWN version — no patch component; release-verify.sh checks `v$SPEC` to match.
rel candor-spec   "v$SPEC" "candor-spec $SPEC"

# --- 4. (the umbrella moved to step 7 — it must follow the pin bump) -----------------------------------

# --- 5. release-verify ----------------------------------------------------------------------------------
say "5. propagation smoke — npm/crates/gh (allow a minute; the real gate is step 8)"
rs_in_set candor-ts && { printf '  npx candor-ts@%s : ' "$VER"; npx -y "candor-ts@$VER" --version 2>/dev/null | grep -o "spec $SPEC" || echo "(not yet on npm — OIDC action still running)"; }
rs_in_set candor-rust && { printf '  cargo query %s   : ' "$VER"; (cargo search candor-query 2>/dev/null | grep -o "$VER") || echo "(propagating)"; }
rs_in_set candor-java && echo "  jbang / brew: run \`jbang candor@tombaldwin/candor-java --version\` and \`brew upgrade candor && candor doctor\` once the java release build finishes."
# --- 6. cross-repo pins, now that the releases they name EXIST ------------------------------------------
say "6. cross-repo pins → $VER"
# NPM_SETTLED: WAIT FOR npm BEFORE THE PINS MOVE, BECAUSE THE PIN-BUMP PUSH IS WHAT STARTS THE CONSUMERS.
#
# `integrations/vscode` and `integrations/jetbrains` pin `candorTsVersion`, and their CI runs
# `stage-server.mjs`, which `npm install`s exactly that version. Bumping the pins and pushing is
# therefore a trigger for two jobs that need candor-ts@$VER to be RESOLVABLE on the registry — and step 2
# only pushed the TAG, which starts an OIDC publish that takes minutes.
#
# MEASURED TWICE. 0.16.0: "candor-ts@0.16.0 wasn't yet on npm when the umbrella push triggered vscode
# extension, so it failed". 0.29.0, the same minute the pins went out: both IDE jobs died on
# `npm error notarget No matching version found for candor-ts@0.29.0`, 22:16:42Z, and both went green on
# a re-run 19 minutes later with nothing changed. The remedy was already written down after 0.16 — "let
# the registries settle FIRST, then push the pin-bump consumers" — and a note that only a human can act
# on is a note that gets skipped at the end of a release. So the script waits instead.
#
# It DIES rather than warns on timeout: the next action this step tells you to take is the push that
# starts those jobs, and doing it against an unpublished version is the failure this exists to stop. A
# genuine publish failure must stop the release, not decorate it.
if ! rs_in_set candor-ts; then
  # The wait exists because the pin bump STARTS the two IDE jobs, which `npm install` candor-ts@$VER. A
  # cut that does not publish candor-ts moves neither IDE ts pin (preflight [3] reports them out of
  # scope), so there is no job to race and no registry to wait for.
  skip "candor-ts is not in this cut — no npm publish to wait for, and neither candorTsVersion pin moves"
elif [ "${NPM_NO_WAIT:-}" = "1" ] || [ -n "${CANDOR_ROOT:-}" ]; then
  # CANDOR_ROOT means a FIXTURE tree (see the header): its "candor-ts" was never published and never
  # will be, so waiting on the real registry for it would hang every harness run for ten minutes.
  skip "npm propagation wait skipped (fixture tree, or NPM_NO_WAIT=1)"
else
  # 25 MINUTES, NOT 10. The publish is not a registry propagation delay — `publish.yml` runs the FULL
  # test battery (behavioural + probe + fuzzer) before it publishes, and its last four successful runs
  # took 11, 11, 10 and 15 minutes. A 10-minute budget therefore LOSES THIS RACE MOST TIMES and reports
  # a healthy release as a failure: measured on the 0.30.0 cut, where it died at 10m against a publish
  # that completed normally. The wait must be sized to the work being waited on, not to a round number —
  # the same error as calling an 18-second job stalled at 3x its median.
  printf '  waiting for candor-ts@%s on npm (publish.yml runs the full battery first; 10-15m is normal) ' "$VER"
  npm_ok=0
  for _ in $(seq 1 150); do                     # 150 × 10s = 25 minutes
    if npm view "candor-ts@$VER" version >/dev/null 2>&1; then npm_ok=1; break; fi
    printf '.'; sleep 10
  done
  echo
  if [ "$npm_ok" = "1" ]; then ok "candor-ts@$VER is resolvable on npm — the consumers will install it"
  else die "candor-ts@$VER is STILL not on npm after 25 minutes — longer than any publish run on record.
     Do NOT push the pin bump yet: it starts the vscode + jetbrains jobs, which npm-install this exact
     version and will fail on it. Check candor-ts's \`publish\` workflow (OIDC), then re-run this
     script — steps 1-3 skip what exists."; fi
fi
echo "  The pins are deliberately NOT moved automatically: each names a published artifact, and 0.24 shipped"
echo "  a jbang pin to a release that did not exist. Update these, commit, push, then run release-verify.sh"
echo "  — which RESOLVES each pinned URL rather than matching the string:"
# ONLY THE PINS THIS CUT MOVES. Each names ONE engine's version, so listing all of them for a one-engine
# patch would instruct the operator to write a version three of the four engines never published — the
# 0.24 failure (a pin naming a release that does not exist) with the operator following the script.
# Enumerated per owner, so this list and preflight [3]'s scoping answer the same question.
if rs_is_full; then
  grep -rn "0\.[0-9]*\.[0-9]*" "$ROOT/candor/bin/candor" 2>/dev/null | grep ENGINE_PIN | head -1
  echo "    · candor/bin/candor           ENGINE_PIN"
  echo "    · candor/adopt/               java + agents pins"
  echo "    · candor-java/jbang-catalog.json"
else
  # THE FRONT DOOR, PER ENGINE. `bin/candor` carries a family pin plus one optional pin per engine, so a
  # scoped cut that INCLUDES the umbrella moves exactly the pins of the engines it published and leaves
  # ENGINE_PIN on the family line. A cut without the umbrella cannot move the front door at all — it is
  # a different repo, with its own release, tag and brew formula.
  if rs_in_set candor; then
    for _e in $RS_PIN_ENGINES; do
      rs_in_set "$(rs_pin_repo "$_e")" && echo "    · candor/bin/candor           ENGINE_PIN_$(printf '%s' "$_e" | tr '[:lower:]' '[:upper:]')=\"$VER\"   (leave ENGINE_PIN on the family line)"
    done
  else
    echo "    · candor/bin/candor           NOT in this cut, so the front door does not move: \`candor update\`"
    echo "      and Homebrew keep installing the family line. To move them, re-cut with the umbrella in the"
    echo "      set:  --only $(printf '%s' "$RS_SET" | tr ' ' ','),candor"
  fi
  rs_in_set candor-java   && echo "    · candor/adopt/candor.yml     CANDOR_JAVA_VERSION"
  rs_in_set candor-agents && echo "    · candor/adopt/candor-digest.yml  candor-agents@v"
  rs_in_set candor-java   && echo "    · candor-java/jbang-catalog.json  (the TAG and the asset FILENAME both)"
  rs_in_set candor-ts     && echo "    · candor/integrations/vscode/package.json          candorTsVersion"
  rs_in_set candor-ts     && echo "    · candor/integrations/jetbrains/gradle.properties  candorTsVersion"
  rs_in_set candor-java   && echo "    · candor/integrations/jetbrains/gradle.properties  candorJavaVersion"
  echo "  THE PIN-BUMP COMMIT MUST ALSO TOUCH THAT REPO'S CHANGELOG — preflight [5b] counts these as SOURCE."
  echo "  Then: bash bin/release-verify.sh $SPEC $VER --only $(printf '%s' "$RS_SET" | tr ' ' ',')"
fi

# --- 7. THE UMBRELLA, LAST, BECAUSE ITS TARBALL CARRIES THE PIN ----------------------------------------
# The umbrella release used to be cut in step 3 and its tag + brew formula in step 4 — both BEFORE step 6
# moves ENGINE_PIN. `scripts/update-candor.sh` hashes the tarball of that tag, so brew would ship a $VER
# umbrella whose `candor update` fetches the PREVIOUS line's engines: a version mismatch nobody sees until
# a new install runs `candor doctor` and reports spec drift against itself. The v0.26.0 tag sits on the
# pin-bump commit, which says the operator hit this and worked around it by hand rather than the script
# recording it. Found by a release-mechanics review, 2026-08-08.
#
# The guard is a CHECK, not a comment: the pin must already name this version or this step refuses.
#
# A SCOPED CUT CAN NOW REACH THIS STEP, and the guard is what makes that safe. `bin/candor` carries a
# family pin plus one optional pin per engine, so the tarball tagged here CAN say "java 0.32.1,
# everything else 0.32.0" — but only if the pins in it name releases that exist. That is one rule over
# four engines (rs_pin_violations in bin/_release_set.sh): every engine this cut publishes must be pinned
# to $VER, and every engine it does NOT publish must be pinned to something else, because $VER was never
# cut for it and a pin naming a release nobody made 404s on the user's machine. Family-wide the rule
# reduces to the ENGINE_PIN == $VER check that has always been here.
say "7. umbrella release + tag + Homebrew tap (AFTER the pins)"
PINNED=$(rs_family_pin "$ROOT/candor/bin/candor")
if ! rs_in_set candor; then
  skip "the umbrella is not in this cut — the front door stays at $PINNED, so \`candor update\`/brew keep installing the family line"
fi
# An umbrella-only CLI patch (`--only candor`, the case `bin/candor`'s own UMBRELLA_VERSION comment
# anticipates) bumps the umbrella while the engine line legitimately stays where it is: no engine repo is
# in the set, so every engine takes the "must NOT name $VER" arm and a front door left where it is passes.
PINVIOL=""
rs_in_set candor && PINVIOL="$(rs_pin_violations "$ROOT/candor/bin/candor" "$VER")"
# Formatted BEFORE the die, never inside it: `release-test.sh` re-renders this die string through a
# heredoc to prove its backticks are escaped, and a command substitution in there would execute during
# that check rather than being inspected by it.
PINMSG="$(printf '%s' "$PINVIOL" | sed 's/^/       · /')"
if [ -n "$PINVIOL" ]; then
  die "ENGINE_PIN mismatch — the umbrella tarball carries the front door's pins and brew hashes it:
$PINMSG
     Cutting the umbrella now ships a $VER front door that installs the wrong engines.
     Do step 6 first (bump the pins in bin/candor + the adopt/jbang pins, commit, push), then re-run
     this script: steps 1-3 skip what already exists and this step will proceed.

     THE PIN-BUMP COMMIT MUST ALSO TOUCH THAT REPO'S CHANGELOG. \`bin/candor\`, \`adopt/*.yml\` and
     jbang-catalog.json all count as SOURCE to preflight [5b] (changelog-lag), which step 0 of this
     script runs unconditionally — so a pins-only commit makes the re-run die at the gate, AFTER the
     engines are published. Add the line to the section this release is cutting — the existing
     \`## [VERSION]\` heading, or for the umbrella its newest DATED heading, which has no version
     section; a new \`## Unreleased\` would trip [9] instead. You do NOT need to wait for CI by hand:
     [10] WAITS for a pending run (20m across all repos) — it only refuses if one is still unfinished
     when that budget runs out, which is the case worth stopping for."
fi
rs_in_set candor && { cd "$ROOT/candor" || die "cannot cd to $ROOT/candor"; }
rel candor "v$VER" "candor v$VER"
if rs_in_set candor; then
# Same remote-existence guard as step 2 — see rs_tag_and_push in _release_set.sh.
rs_tag_and_push "v$VER" ""; utprc=$?
case "$utprc" in
  3) skip "umbrella tag v$VER already on origin" ;;
  0) ok "umbrella v$VER" ;;
  *) die "umbrella: v$VER did not reach origin — see the message above. Fix access/network and re-run;
     the local tag is kept and reused, only the push repeats." ;;
esac
# PASS THE TAG, NOT THE BARE VERSION. update-candor.sh tags whatever string it is handed and its usage line
# asks for `v0.16.0`; this passed `$VER`, so every release grew a SECOND umbrella tag and a second GitHub
# release beside `v$VER` — 0.25 and 0.26 both carry the pair. Harmless (both resolve) and untidy, and the
# tap formula ended up pointing at the odd one out.
if [ -x "$ROOT/candor/scripts/update-candor.sh" ]; then bash "$ROOT/candor/scripts/update-candor.sh" "v$VER" && ok "brew tap → v$VER" || die "update-candor.sh failed (tap may need a reconcile — see [[candor-history-2026-06]])"; fi
fi

# --- 8. release-verify — RUN IT, do not just tell the operator to -----------------------------------
# `release-verify.sh` is the only step in this whole ladder that RESOLVES what it checks rather than
# string-matching it: it fetches the pinned URLs and confirms a fresh install reports the floor, instead
# of trusting that a version string in a file means the artifact behind it exists and works. On the
# 0.33.0 cut it was the ONLY thing that caught candor-swift's release sitting in DRAFT state — the binary
# had built and attached fine, the API reported the asset `state=uploaded`, and every download 404'd
# anyway, because a draft release serves 404 on every asset regardless of what the API says about it.
#
# Until now this was a separate step an operator had to remember to run, documented in the very message
# this replaces — "verify each channel… then run release-verify.sh". A release that skips it is not
# verified, and the whole point of automating the ladder is that the LAST step is not the one most likely
# to be forgotten because everything before it already worked.
#
# SAME SCOPE AS THE CUT. `--only` on this run must equal `--only` on the cut: verifying MORE than was
# published asks a question about repos this run never touched (their genuine unrelated staleness would
# read as this release's failure); verifying LESS would let a scoped cut's own artifacts go unconfirmed.
say "8. release-verify (resolves every pinned URL and GitHub Release — see the note above)"
VERIFY_ONLY=""
rs_is_full || VERIFY_ONLY="--only $(printf '%s' "$RS_SET" | tr ' ' ',')"
# shellcheck disable=SC2086  # deliberately unquoted: empty must vanish as zero args, not pass as ""
if bash "$ROOT/candor/bin/release-verify.sh" "$SPEC" "$VER" $VERIFY_ONLY; then
  ok "release-verify OK"
else
  # THE EXIT CODE IS release-verify's OWN, not a fixed 1 — `die` always exits 1, which would erase the
  # distinction its caller (a CI job, another script) might want between "verify found N problems" and
  # any other failure. The publish above already happened; this failure means it did not VERIFY, which
  # is a different, still-serious, fact — reported loudly rather than folded into a generic die.
  vrc=$?
  printf '  \033[31m✘ release-verify FAILED (exit %s) — the publish above SUCCEEDED but did not verify.\033[0m\n' "$vrc"
  printf '  \033[31m  See the output above. Fix it, then re-run:  bash bin/release-verify.sh %s %s%s\033[0m\n' \
    "$SPEC" "$VER" "${VERIFY_ONLY:+ $VERIFY_ONLY}"
  exit "$vrc"
fi

if rs_is_full; then
say "DONE — $SPEC / $VER published and verified live everywhere."
else
say "DONE — $VER published and verified for: $RS_SET (spec floor stays $SPEC). The rest of the family is unchanged."
fi
