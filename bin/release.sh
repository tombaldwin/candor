#!/usr/bin/env bash
# release.sh — one-command publish of a staged candor floor. Run it when you can grant the publish permissions
# (or from your own terminal). It assumes the version is ALREADY bumped + committed + pushed on every repo's main
# (that is `bin/release-preflight.sh`'s job); this script only PUBLISHES, in the order that has bitten us before.
#
#   bash bin/release.sh 0.22 0.22.0
#
# Idempotent-ish: a crate/release that already exists is skipped with a note, so a re-run after a mid-way failure
# resumes cleanly. Stops on the first UNexpected error. Needs: crates.io token (~/.cargo/credentials.toml), gh auth,
# and push access. npm needs NO local token — the candor-ts tag triggers the OIDC publish.yml (SLSA provenance).
set -uo pipefail
SPEC="${1:?usage: release.sh <spec e.g. 0.22> <version e.g. 0.22.0>}"
VER="${2:?usage: release.sh <spec> <version>}"
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
# PINS_ADVISORY: check [3] asserts the cross-repo pins name $VER, and they cannot until this script has
# published $VER. Strict here is a deadlock, not a safeguard — see the note in release-preflight.sh. The
# pins are updated in step 6 below and then RESOLVED by release-verify.sh, which is the check that matters.
PINS_ADVISORY=1 bash "$ROOT/candor/bin/release-preflight.sh" "$SPEC" "$VER" >/tmp/rel-preflight.txt 2>&1 \
  && ok "release-preflight OK (cross-repo pins advisory — they move in step 6)" \
  || die "release-preflight FAILED — see /tmp/rel-preflight.txt"
for r in candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor; do
  [ -z "$(git -C "$ROOT/$r" status --porcelain)" ] || die "$r has uncommitted changes — commit + push first"
  [ "$(git -C "$ROOT/$r" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)" = "0" ] || die "$r has unpushed commits — push main first"
done
ok "all mains clean + pushed"

# --- 1. crates.io — STRICT dep order (report → classify → scan → query) ----------------------------------
# cargo publish waits for index propagation of each dep before the next resolves. A crate already at $VER on
# crates.io errors "already uploaded" → we treat that as a skip and continue.
say "1. crates.io (dep order)"
cd "$ROOT/candor-rust" || die "cannot cd to $ROOT/candor-rust"
for crate in candor-report candor-classify candor-scan candor-query; do
  if cargo publish -p "$crate" 2>/tmp/rel-$crate.txt; then ok "published $crate@$VER"
  elif grep -qiE "already (uploaded|exists)|crate version .* is already" /tmp/rel-$crate.txt; then skip "$crate@$VER already on crates.io"
  else cat /tmp/rel-$crate.txt; die "cargo publish -p $crate failed"; fi
done

# --- 2. candor-ts → npm via the tag-triggered OIDC action (never manual npm publish) ---------------------
say "2. candor-ts npm (via v$VER tag → OIDC publish.yml)"
cd "$ROOT/candor-ts" || die "cannot cd to $ROOT/candor-ts"
if git rev-parse "v$VER" >/dev/null 2>&1; then skip "tag v$VER already exists"
else git tag "v$VER" && git push origin "v$VER" && ok "tagged + pushed v$VER (OIDC action publishes candor-ts@$VER with provenance)"; fi

# --- 3. GitHub releases (java release triggers native.yml + needs the jar asset) -------------------------
say "3. GitHub releases"
JAR="$(ls "$ROOT"/candor-java/build/libs/candor-java-"$VER"-all.jar 2>/dev/null || true)"
[ -n "$JAR" ] || die "candor-java-$VER-all.jar not built — run ./gradlew shadowJar in candor-java first"
rel() { # $1 repo ; $2 tag ; $3 title ; shift 3 ; extra assets
  local repo="$1" tag="$2" title="$3"; shift 3
  if gh release view "$tag" -R "tombaldwin/$repo" >/dev/null 2>&1; then skip "$repo $tag already released"
  else
    # THE BODY IS THE NEWEST ENTRY, NOT THE WHOLE CHANGELOG. GitHub caps a release body at 125000
    # characters and candor-swift's CHANGELOG is 154KB, so `-F CHANGELOG.md` 422'd mid-release on 0.25
    # ("body is too long") and left that repo TAGGED WITH NO RELEASE — the state that broke `candor
    # update` at 0.24. Every other changelog is growing the same way, so this was a deadline, not a one-off.
    # SELECT BY VERSION, NOT BY POSITION. This read "the first `## ` section", which was correct only
    # while the newest entry happened to be first. `release-stage.sh` opens a FRESH EMPTY `## Unreleased`
    # above the entry it just cut, so on 0.26 — the first release where the two scripts ran together —
    # this extracted two blank lines and would have published EMPTY notes for all five engines. Anchoring
    # on `## [$VER]` cannot drift that way, and an empty result is now fatal rather than silent.
    awk -v v="## [$VER]" 'index($0,v)==1{f=1;print;next} f&&/^## /{exit} f{print}' \
        "$ROOT/$repo/CHANGELOG.md" | head -80 > "/tmp/rel-body-$repo.md"
    # THE UMBRELLA'S CHANGELOG IS DATED, NOT VERSIONED, AND SAYS SO IN ITS OWN HEADER: "not a versioned
    # release artifact — it pins the engine versions it targets, so this changelog is DATED". So it has no
    # `## [X.Y.Z]` heading and never should. Fall back to the newest section for that shape — but only as a
    # FALLBACK, so the five engines still get the version-anchored selection that stops the empty-notes bug,
    # and an empty result stays fatal either way.
    # candor-spec's headings are FLOOR-shaped (`## 0.27 — …`), not `## [0.27.0]`, so the version anchor
    # above misses it. Try the floor before falling back to position.
    if [ ! -s "/tmp/rel-body-$repo.md" ]; then
      awk -v v="## $SPEC " 'index($0,v)==1{f=1;print;next} f&&/^## /{exit} f{print}' \
          "$ROOT/$repo/CHANGELOG.md" | head -80 > "/tmp/rel-body-$repo.md"
    fi
    if [ ! -s "/tmp/rel-body-$repo.md" ]; then
      # SKIP A FRESH EMPTY `## Unreleased`. Staging opens one at the top, so "the newest section" is now
      # that heading and its single line of body — which passes the empty-file and whitespace-only guards
      # below and would publish a release whose notes read, in full, `## Unreleased`. That is the 0.26
      # empty-notes defect with one line of camouflage; it did not fire then only because no empty
      # Unreleased sat on top yet. Found by a release-mechanics review, 2026-08-08.
      # `\[?…\]?`: the bracketed `## [Unreleased]` is the other spelling this family writes, and the first
      # version of this skip matched only the bare one — an empty bracketed heading published as a
      # one-line body. Unreachable for 0.27.0 (only the umbrella reaches this fallback and it has no
      # Unreleased heading) but a one-spelling guard is how the defect it fixes got in.
      awk '/^## \[?[Uu]nreleased\]?/{skip=1;next} /^## /{if(skip){skip=0;n++} else n++} n==1&&!skip{print} n==2{exit}' \
          "$ROOT/$repo/CHANGELOG.md" | head -80 > "/tmp/rel-body-$repo.md"
      skip "$repo: no '## [$VER]' heading (dated changelog) — using the newest non-empty section"
    fi
    [ -s "/tmp/rel-body-$repo.md" ] || die "$repo: CHANGELOG yields no release notes — refusing to publish an empty release"
    grep -q '[^[:space:]]' "/tmp/rel-body-$repo.md" || die "$repo: release notes are whitespace only — refusing"
    gh release create "$tag" "$@" -R "tombaldwin/$repo" -t "$title" -F "/tmp/rel-body-$repo.md" && ok "$repo $tag"
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
say "5. release-verify (allow a minute for npm/crates/gh to propagate)"
printf '  npx candor-ts@%s : ' "$VER"; npx -y "candor-ts@$VER" --version 2>/dev/null | grep -o "spec $SPEC" || echo "(not yet on npm — OIDC action still running)"
printf '  cargo query %s   : ' "$VER"; (cargo search candor-query 2>/dev/null | grep -o "$VER") || echo "(propagating)"
echo "  jbang / brew: run \`jbang candor@tombaldwin/candor-java --version\` and \`brew upgrade candor && candor doctor\` once the java release build finishes."
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
if [ "${NPM_NO_WAIT:-}" = "1" ] || [ -n "${CANDOR_ROOT:-}" ]; then
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
grep -rn "0\.[0-9]*\.[0-9]*" "$ROOT/candor/bin/candor" 2>/dev/null | grep ENGINE_PIN | head -1
echo "    · candor/bin/candor           ENGINE_PIN"
echo "    · candor/adopt/               java + agents pins"
echo "    · candor-java/jbang-catalog.json"

# --- 7. THE UMBRELLA, LAST, BECAUSE ITS TARBALL CARRIES THE PIN ----------------------------------------
# The umbrella release used to be cut in step 3 and its tag + brew formula in step 4 — both BEFORE step 6
# moves ENGINE_PIN. `scripts/update-candor.sh` hashes the tarball of that tag, so brew would ship a $VER
# umbrella whose `candor update` fetches the PREVIOUS line's engines: a version mismatch nobody sees until
# a new install runs `candor doctor` and reports spec drift against itself. The v0.26.0 tag sits on the
# pin-bump commit, which says the operator hit this and worked around it by hand rather than the script
# recording it. Found by a release-mechanics review, 2026-08-08.
#
# The guard is a CHECK, not a comment: the pin must already name this version or this step refuses.
say "7. umbrella release + tag + Homebrew tap (AFTER the pins)"
PINNED=$(grep -oE 'ENGINE_PIN="[0-9]+\.[0-9]+\.[0-9]+"' "$ROOT/candor/bin/candor" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
if [ "$PINNED" != "$VER" ]; then
  die "ENGINE_PIN is ${PINNED:-unset}, not $VER — the umbrella tarball carries that pin and brew hashes it,
     so cutting the umbrella now ships a $VER front door that fetches ${PINNED:-the wrong} engines.
     Do step 6 first (bump ENGINE_PIN + the adopt/jbang pins, commit, push), then re-run this script:
     steps 1-3 skip what already exists and this step will proceed.

     THE PIN-BUMP COMMIT MUST ALSO TOUCH THAT REPO'S CHANGELOG. \`bin/candor\`, \`adopt/*.yml\` and
     jbang-catalog.json all count as SOURCE to preflight [5b] (changelog-lag), which step 0 of this
     script runs unconditionally — so a pins-only commit makes the re-run die at the gate, AFTER the
     engines are published. Add the line to the section this release is cutting — the existing
     \`## [VERSION]\` heading, or for the umbrella its newest DATED heading, which has no version
     section; a new \`## Unreleased\` would trip [9] instead. You do NOT need to wait for CI by hand:
     [10] WAITS for a pending run (20m across all repos) — it only refuses if one is still unfinished
     when that budget runs out, which is the case worth stopping for."
fi
cd "$ROOT/candor" || die "cannot cd to $ROOT/candor"
rel candor "v$VER" "candor v$VER"
git rev-parse "v$VER" >/dev/null 2>&1 && skip "umbrella tag v$VER exists" || { git tag "v$VER" && git push origin "v$VER" && ok "umbrella v$VER"; }
# PASS THE TAG, NOT THE BARE VERSION. update-candor.sh tags whatever string it is handed and its usage line
# asks for `v0.16.0`; this passed `$VER`, so every release grew a SECOND umbrella tag and a second GitHub
# release beside `v$VER` — 0.25 and 0.26 both carry the pair. Harmless (both resolve) and untidy, and the
# tap formula ended up pointing at the odd one out.
if [ -x "$ROOT/candor/scripts/update-candor.sh" ]; then bash "$ROOT/candor/scripts/update-candor.sh" "v$VER" && ok "brew tap → v$VER" || die "update-candor.sh failed (tap may need a reconcile — see [[candor-history-2026-06]])"; fi

say "DONE — $SPEC / $VER published. Verify each channel reports spec $SPEC, then run release-verify.sh."
