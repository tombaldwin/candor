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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # dir holding candor-* siblings
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
cd "$ROOT/candor-rust"
for crate in candor-report candor-classify candor-scan candor-query; do
  if cargo publish -p "$crate" 2>/tmp/rel-$crate.txt; then ok "published $crate@$VER"
  elif grep -qiE "already (uploaded|exists)|crate version .* is already" /tmp/rel-$crate.txt; then skip "$crate@$VER already on crates.io"
  else cat /tmp/rel-$crate.txt; die "cargo publish -p $crate failed"; fi
done

# --- 2. candor-ts → npm via the tag-triggered OIDC action (never manual npm publish) ---------------------
say "2. candor-ts npm (via v$VER tag → OIDC publish.yml)"
cd "$ROOT/candor-ts"
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
    if [ ! -s "/tmp/rel-body-$repo.md" ]; then
      awk '/^## /{n++} n==1{print} n==2{exit}' "$ROOT/$repo/CHANGELOG.md" | head -80 > "/tmp/rel-body-$repo.md"
      skip "$repo: no '## [$VER]' heading (dated changelog) — using the newest section"
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
rel candor        "v$VER" "candor v$VER"
# the SPEC is tagged at its OWN version — no patch component; release-verify.sh checks `v$SPEC` to match.
rel candor-spec   "v$SPEC" "candor-spec $SPEC"

# --- 4. umbrella + Homebrew front door ------------------------------------------------------------------
say "4. umbrella tag + Homebrew tap"
cd "$ROOT/candor"
git rev-parse "v$VER" >/dev/null 2>&1 && skip "umbrella tag v$VER exists" || { git tag "v$VER" && git push origin "v$VER" && ok "umbrella v$VER"; }
if [ -x "$ROOT/candor/scripts/update-candor.sh" ]; then bash "$ROOT/candor/scripts/update-candor.sh" "$VER" && ok "brew tap → $VER" || die "update-candor.sh failed (tap may need a reconcile — see [[candor-history-2026-06]])"; fi

# --- 5. release-verify ----------------------------------------------------------------------------------
say "5. release-verify (allow a minute for npm/crates/gh to propagate)"
printf '  npx candor-ts@%s : ' "$VER"; npx -y "candor-ts@$VER" --version 2>/dev/null | grep -o "spec $SPEC" || echo "(not yet on npm — OIDC action still running)"
printf '  cargo query %s   : ' "$VER"; (cargo search candor-query 2>/dev/null | grep -o "$VER") || echo "(propagating)"
echo "  jbang / brew: run \`jbang candor@tombaldwin/candor-java --version\` and \`brew upgrade candor && candor doctor\` once the java release build finishes."
# --- 6. cross-repo pins, now that the releases they name EXIST ------------------------------------------
say "6. cross-repo pins → $VER"
echo "  The pins are deliberately NOT moved automatically: each names a published artifact, and 0.24 shipped"
echo "  a jbang pin to a release that did not exist. Update these, commit, push, then run release-verify.sh"
echo "  — which RESOLVES each pinned URL rather than matching the string:"
grep -rn "0\.[0-9]*\.[0-9]*" "$ROOT/candor/bin/candor" 2>/dev/null | grep ENGINE_PIN | head -1
echo "    · candor/bin/candor           ENGINE_PIN"
echo "    · candor/adopt/               java + agents pins"
echo "    · candor-java/jbang-catalog.json"

say "DONE — $SPEC / $VER published. Verify each channel reports spec $SPEC, then run release-verify.sh."
